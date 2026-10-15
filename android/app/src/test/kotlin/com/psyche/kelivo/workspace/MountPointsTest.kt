package com.psyche.kelivo.workspace

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class MountPointsTest {
    @get:Rule val temporary = TemporaryFolder()

    private fun installedRootfs(): File = temporary.newFolder("rootfs").apply {
        File(this, "bin/sh").apply { parentFile.mkdirs(); writeText("#!/bin/sh\n") }
    }

    @Test
    fun occupancyAcceptsMissingAndEmptyTargetsOnly() {
        val rootfs = installedRootfs()
        val binds = listOf(BindMount("/host/notes", "/root/Notes"))
        MountPoints.requireFreeTargets(rootfs, binds)
        File(rootfs, "root/Notes").mkdirs()
        MountPoints.requireFreeTargets(rootfs, binds)
        File(rootfs, "root/Notes/local.txt").writeText("mine")
        assertTrue(occupied(rootfs, binds))
        assertEquals("mine", File(rootfs, "root/Notes/local.txt").readText())
        File(rootfs, "root/Notes").deleteRecursively()
        File(rootfs, "root/Notes").writeText("a file, not a directory")
        assertTrue(occupied(rootfs, binds))
        assertEquals("a file, not a directory", File(rootfs, "root/Notes").readText())
    }

    @Test
    fun nothingIsCreatedBeforeTheRootfsIsInstalled() {
        val bare = temporary.newFolder("bare")
        MountPoints.ensure(bare, listOf(BindMount("/host/notes", "/root/Notes")))
        assertFalse(File(bare, "root/Notes").exists())
    }

    @Test
    fun ensureCreatesAndRecordsOnlyTheTargetsItCreated() {
        val rootfs = installedRootfs()
        val notes = BindMount("/host/notes", "/root/Notes")
        val existing = BindMount("/host/existing", "/opt/existing")
        File(rootfs, "opt/existing").mkdirs()
        MountPoints.ensure(rootfs, listOf(notes, existing))
        assertTrue(File(rootfs, "root/Notes").isDirectory)
        assertTrue(File(rootfs, "opt/existing").isDirectory)
        assertEquals(setOf("/root/Notes"), MountPoints.readPlaceholders(rootfs))

        // A target the user made is never recorded, so unmounting leaves it alone.
        MountPoints.release(rootfs, emptyList())
        assertFalse(File(rootfs, "root/Notes").exists())
        assertTrue(File(rootfs, "opt/existing").isDirectory)
        assertTrue(MountPoints.readPlaceholders(rootfs).isEmpty())
    }

    @Test
    fun releaseRemovesOnlyEmptyTargetsThisAppCreated() {
        val rootfs = installedRootfs()
        val notes = BindMount("/host/notes", "/root/Notes")
        val data = BindMount("/host/data", "/opt/data")
        MountPoints.ensure(rootfs, listOf(notes, data))
        File(rootfs, "opt/data/keep.txt").writeText("keep")

        // Dropping a mount whose directory holds files keeps the files.
        MountPoints.release(rootfs, listOf(notes))
        assertTrue(File(rootfs, "root/Notes").isDirectory)
        assertEquals("keep", File(rootfs, "opt/data/keep.txt").readText())
        assertEquals(setOf("/root/Notes"), MountPoints.readPlaceholders(rootfs))

        MountPoints.release(rootfs, emptyList())
        assertFalse(File(rootfs, "root/Notes").exists())
        assertEquals("keep", File(rootfs, "opt/data/keep.txt").readText())
        assertTrue(MountPoints.readPlaceholders(rootfs).isEmpty())
    }

    private fun occupied(rootfs: File, binds: List<BindMount>): Boolean {
        val error = runCatching {
            MountPoints.requireFreeTargets(rootfs, binds)
        }.exceptionOrNull()
        return error is MountTargetOccupiedException
    }
}
