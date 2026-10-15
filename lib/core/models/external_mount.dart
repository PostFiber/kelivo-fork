import 'package:path/path.dart' as p;

import 'workspace_directory_access.dart';

/// A folder the user granted to the sandbox, mounted at an absolute guest path.
class ExternalMount {
  const ExternalMount({
    required this.id,
    required this.guestPath,
    required this.access,
    required this.sourcePath,
    this.readOnly = false,
  });

  /// Guest paths a mount must not cover: the app's own zones, and the system
  /// paths the sandbox needs (`/dev`, `/proc` and `/sys` are bound by PRoot
  /// itself, and iOS binds `/etc/resolv.conf`). This is the only copy of the
  /// policy; the runners receive it with every mount and enforce what they get.
  static const reservedGuestPaths = [
    '/workspace',
    '/chat',
    '/skills',
    '/tmp',
    '/dev',
    '/proc',
    '/sys',
    '/etc',
  ];

  static const maxGuestPathLength = 200;

  final String id;

  /// Absolute path inside the sandbox guest. Mounts never nest and never sit on
  /// a [reservedGuestPaths] path.
  final String guestPath;
  final WorkspaceDirectoryAccess access;
  final String sourcePath;
  final bool readOnly;

  /// Display label. The guest path above carries the full identity.
  String get name => p.posix.basename(guestPath);

  ExternalMount copyWith({
    String? guestPath,
    WorkspaceDirectoryAccess? access,
    String? sourcePath,
    bool? readOnly,
  }) => ExternalMount(
    id: id,
    guestPath: guestPath ?? this.guestPath,
    access: access ?? this.access,
    sourcePath: sourcePath ?? this.sourcePath,
    readOnly: readOnly ?? this.readOnly,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'guestPath': guestPath,
    'access': access.toJson(),
    'sourcePath': sourcePath,
    'readOnly': readOnly,
  };

  factory ExternalMount.fromJson(Map<String, dynamic> json) => ExternalMount(
    id: json['id'] as String,
    guestPath: json['guestPath'] as String,
    access: WorkspaceDirectoryAccess.fromJson(
      Map<String, dynamic>.from(json['access'] as Map),
    ),
    sourcePath: json['sourcePath'] as String,
    readOnly: json['readOnly'] as bool,
  );

  /// A normalized absolute path, free of what PRoot's `-b host:guest` cannot
  /// carry (`:` is its delimiter).
  static bool validGuestPath(String path) {
    if (path.isEmpty || path.length > maxGuestPathLength) return false;
    if (!path.startsWith('/') || path == '/' || path.endsWith('/')) {
      return false;
    }
    if (path.contains(RegExp(r'[:\\\x00-\x1f\x7f]'))) return false;
    return p.posix.normalize(path) == path;
  }

  /// True when [path] is a reserved path, sits inside one, or contains one.
  static bool reservedGuestPath(String path) {
    for (final reserved in reservedGuestPaths) {
      if (path == reserved ||
          p.posix.isWithin(reserved, path) ||
          p.posix.isWithin(path, reserved)) {
        return true;
      }
    }
    return false;
  }

  /// True when one of the two guest paths contains the other.
  static bool nestedGuestPaths(String a, String b) =>
      p.posix.isWithin(a, b) || p.posix.isWithin(b, a);
}
