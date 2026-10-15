package com.psyche.kelivo.workspace

import java.io.File

/** An absolute guest path, never the root, free of the separators a bind
 * argument and the newline-separated guard records cannot carry. Format policy
 * (length, dots, slashes) is Dart's, which also supplies the reserved list. */
internal fun validGuestPath(path: String): Boolean {
    if (path.isEmpty() || !path.startsWith('/') || path == "/") return false
    return path.none { it == ':' || it == '\u0000' || it.code < 32 || it.code == 127 }
}

/** True when [path] is a reserved path, sits inside one, or contains one. */
internal fun coversReservedPath(reserved: List<String>, path: String): Boolean =
    reserved.any { path == it || path.startsWith("$it/") || it.startsWith("$path/") }

/** True when one of the two guest paths contains the other. */
internal fun nestedGuestPaths(a: String, b: String): Boolean =
    a.startsWith("$b/") || b.startsWith("$a/")

internal class MountTargetOccupiedException(val guest: String) :
    Exception("The guest path already holds files: $guest")

/**
 * PRoot does not create bind targets, so the app makes the guest directories it
 * needs. The directories it created are recorded inside the rootfs, so a later
 * unmount removes only those, and only while they are still empty.
 */
internal object MountPoints {
    private const val RECORD = "run/kelivo/mount-placeholders"
    private val installedProbe = "/bin/sh"

    fun readPlaceholders(rootfs: File): MutableSet<String> {
        val file = File(rootfs, RECORD)
        if (!file.isFile) return mutableSetOf()
        return file.readLines().map(String::trim).filter(String::isNotEmpty)
            .toMutableSet()
    }

    private fun writePlaceholders(rootfs: File, guests: Set<String>) {
        val file = File(rootfs, RECORD)
        if (guests.isEmpty()) {
            file.delete()
            return
        }
        file.parentFile?.mkdirs()
        file.writeText(guests.sorted().joinToString("\n", postfix = "\n"))
    }

    /** A target this app created once is not "occupied" by the user's files. */
    fun requireFreeTargets(rootfs: File, mounts: List<BindMount>) {
        if (!rootfs.isDirectory) return
        val placeholders = readPlaceholders(rootfs)
        for (mount in mounts) {
            val target = RootfsInfo.guestFile(rootfs, mount.guest)
            if (!target.exists()) continue
            if (!target.isDirectory) throw MountTargetOccupiedException(mount.guest)
            val entries = target.list()
            if (entries != null && entries.isNotEmpty() && mount.guest !in placeholders) {
                throw MountTargetOccupiedException(mount.guest)
            }
        }
    }

    /** Create the bind targets that are missing, remembering the ones we create. */
    fun ensure(rootfs: File, mounts: List<BindMount>) {
        if (mounts.isEmpty() || !RootfsInfo.guestFile(rootfs, installedProbe).isFile) return
        val placeholders = readPlaceholders(rootfs)
        var changed = false
        for (mount in mounts) {
            val target = RootfsInfo.guestFile(rootfs, mount.guest)
            if (target.exists()) {
                if (!target.isDirectory) throw MountTargetOccupiedException(mount.guest)
                continue
            }
            if (target.mkdirs()) {
                placeholders += mount.guest
                changed = true
            }
        }
        if (changed) writePlaceholders(rootfs, placeholders)
    }

    /** Forget the placeholders of mounts that are gone, removing the empty ones. */
    fun release(rootfs: File, keep: List<BindMount>) {
        if (!rootfs.isDirectory) return
        val placeholders = readPlaceholders(rootfs)
        if (placeholders.isEmpty()) return
        val kept = keep.map { it.guest }.toSet()
        val dropped = placeholders.filter { it !in kept }
        if (dropped.isEmpty()) return
        for (guest in dropped) {
            val target = runCatching { RootfsInfo.guestFile(rootfs, guest) }.getOrNull()
            if (target != null && target.isDirectory && target.list()?.isEmpty() == true) {
                target.delete()
            }
        }
        placeholders.removeAll(dropped.toSet())
        writePlaceholders(rootfs, placeholders)
    }
}
