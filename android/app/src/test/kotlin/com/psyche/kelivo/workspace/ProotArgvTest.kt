package com.psyche.kelivo.workspace

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Assume.assumeTrue
import org.junit.Test

class ProotArgvTest {
    @Test
    fun execArgvMatchesGoldenString() {
        val launch = ProotCommand.build(
            nativeLibDir = File("/nativelib"),
            rootfsDir = File("/data/rootfs"),
            tmpDir = File("/data/tmp"),
            binds = listOf(BindMount("/host/files", "/workspace")),
            cwd = "/workspace",
            command = "echo hello",
            env = linkedMapOf(
                "HOME" to "/root",
                "PATH" to "/bin",
            ),
            includeLibraryPath = true,
        )
        val golden =
            "/nativelib/libproot_exec.so --root-id --link2symlink --kill-on-exit " +
                "-r /data/rootfs -w /workspace -b /host/files:/workspace " +
                "-b /dev -b /proc -b /sys /usr/bin/env -i HOME=/root PATH=/bin LANG=C.UTF-8 " +
                "/bin/sh -lc " + ProotCommand.BASH_EVAL + " kelivo /workspace echo hello"
        assertEquals(golden, launch.argv.joinToString(" "))
        assertEquals("/data", launch.workingDirectory.absolutePath)
        assertEquals("/nativelib/libproot_loader.so", launch.processEnv["PROOT_LOADER"])
        assertEquals("/data/tmp", launch.processEnv["PROOT_TMP_DIR"])
        assertEquals("/data/tmp", launch.processEnv["TMPDIR"])
        assertEquals("/data/tmp:/nativelib", launch.processEnv["LD_LIBRARY_PATH"])
    }

    @Test
    fun ptyArgvUsesLoginShellAndTerm() {
        val launch = ProotCommand.build(
            nativeLibDir = File("/nativelib"),
            rootfsDir = File("/data/rootfs"),
            tmpDir = File("/data/tmp"),
            binds = emptyList(),
            cwd = "/root",
            command = null,
            env = linkedMapOf("HOME" to "/root"),
            includeLibraryPath = false,
        )
        assertEquals("/bin/sh", launch.argv[launch.argv.size - 2])
        assertEquals("-l", launch.argv.last())
        assertEquals("HOME=/root", launch.argv[launch.argv.indexOf("-i") + 1])
        assertTrue(launch.argv.contains("TERM=xterm-256color"))
        assertTrue(launch.argv.contains("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"))
    }

    @Test
    fun emptyExecEnvironmentExportsGuestDefaultsToChildProcesses() {
        assumeTrue(File("/bin/bash").canExecute() && File("/usr/bin/env").canExecute())
        val launch = ProotCommand.build(
            nativeLibDir = File("/nativelib"),
            rootfsDir = File("/data/rootfs"),
            tmpDir = File("/data/tmp"),
            binds = emptyList(),
            cwd = "/",
            command = "/usr/bin/env",
            shell = "/bin/bash",
            env = emptyMap(),
            includeLibraryPath = false,
        )
        val argv = launch.argv.drop(launch.argv.indexOf("/usr/bin/env")).toMutableList()
        // Run the guest shell launch on the test host without its login profiles,
        // which could mask a missing exported PATH by setting one themselves.
        argv.addAll(argv.indexOf("/bin/bash") + 1, listOf("--noprofile", "--norc"))
        val process = ProcessBuilder(argv).redirectErrorStream(true).start()
        val output = process.inputStream.bufferedReader().use { it.readText() }
        assertEquals(output, 0, process.waitFor())
        val lines = output.lineSequence().toSet()
        assertTrue(output, lines.contains("PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"))
        assertTrue(output, lines.contains("HOME=/root"))
        assertTrue(output, lines.contains("LANG=C.UTF-8"))
    }

    @Test
    fun readOnlyPreferenceUsesUnmodifiedProotForExecAndPty() {
        // A Windows drive path always carries the ':' proot reserves as its
        // host:guest delimiter, so no host path passes on that platform.
        assumeTrue(File("/storage/Notes").isAbsolute)
        for (command in listOf("echo hello", null)) {
            val binds = listOf(BindMount("/storage/My Notes", "/root/Notes", true))
            validateExternalMounts(binds, reservedPaths)
            val launch = ProotCommand.build(File("/libs"), File("/rootfs"), File("/tmp"), binds, "/workspace", command, emptyMap())
            assertEquals("/libs/libproot_exec.so", launch.argv.first())
            assertTrue(launch.argv.contains("/storage/My Notes:/root/Notes"))
            assertFalse(launch.argv.any { it.startsWith("--read-only") })
            assertFalse(launch.processEnv.containsKey("PROOT_NO_SECCOMP"))
        }
    }

    @Test
    fun externalMountsAcceptAnyFreeGuestPath() {
        // A Windows drive path always carries the ':' proot reserves as its
        // host:guest delimiter, so no host path passes on that platform.
        assumeTrue(File("/storage/Notes").isAbsolute)
        validateExternalMounts(
            listOf(
                BindMount("/storage/Notes", "/root/Notes"),
                BindMount("/storage/Data", "/opt/data"),
                BindMount("/storage/Cache", "/srv/app/cache"),
            ),
            reservedPaths,
        )
    }

    @Test
    fun externalMountGuestsMustBeStructurallyBindablePaths() {
        // Path format (normalization, length) is Dart's; native keeps only the
        // structure an argv element and the guard records can carry.
        for (guest in listOf("root/Notes", "/", "", "/root/No:tes", "/root/No\ntes")) {
            assertRejected(listOf(BindMount("/storage/Notes", guest)))
        }
    }

    @Test
    fun emptyReservedListReservesNothing() {
        // Native holds no reserved-path list of its own: it enforces the one
        // Dart sends, so an empty list means no path is reserved.
        assumeTrue(File("/storage/Notes").isAbsolute)
        validateExternalMounts(
            listOf(BindMount("/storage/Notes", "/workspace/docs")),
            emptyList(),
        )
    }

    @Test
    fun reservedPathsAreTheCallersPolicy() {
        assertRejected(listOf(BindMount("/storage/Notes", "/workspace")))
        assertRejected(listOf(BindMount("/storage/Notes", "/workspace/docs")))
        assertRejected(listOf(BindMount("/storage/Notes", "/dev/pts")))
        // An ancestor of a reserved path shadows it just as badly.
        assertRejected(listOf(BindMount("/storage/Notes", "/srv")), listOf("/srv/app"))
    }

    @Test
    fun externalMountGuestsCannotNestEachOther() {
        assertRejected(
            listOf(
                BindMount("/storage/Notes", "/root/Notes"),
                BindMount("/storage/Inner", "/root/Notes/inner"),
                BindMount("/storage/Outer", "/root"),
            ),
        )
    }

    @Test
    fun externalMountGuestsMustBeUniqueRegardlessOfCase() {
        assertRejected(
            listOf(
                BindMount("/storage/Notes", "/root/Notes"),
                BindMount("/storage/Other", "/ROOT/notes"),
            ),
        )
    }

    @Test
    fun externalMountHostCannotInjectProotDelimiter() {
        assertRejected(listOf(BindMount("/storage/Notes:other", "/root/Notes")))
    }

    private fun assertRejected(
        binds: List<BindMount>,
        reserved: List<String> = reservedPaths,
    ) {
        try {
            validateExternalMounts(binds, reserved)
        } catch (_: IllegalArgumentException) {
            return
        }
        fail("expected rejection: ${binds.map { it.guest }}")
    }

    private companion object {
        val reservedPaths =
            listOf("/workspace", "/chat", "/skills", "/tmp", "/dev", "/proc", "/sys", "/etc")
    }
}
