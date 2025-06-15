// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

// const extensionId = 'loofnacbmbaonpphbedakggdnhlpmhne';
const extensionId = 'dicdpbofeeifbofnkcioongmplpjmoal';
// Set this path if you want to monitor an unpacked extension's source directory directly.
// Example: const unpackedExtensionSourceDirectoryPath = '/Users/youruser/Projects/MyChromeExtensionSource';
const String unpackedExtensionSourceDirectoryPath =
    'Desktop/Projects/profile-locker/chrome-profile-locker'; // Replace null with the actual path string if needed

void main() {
  runApp(ProfileMonitorApp());
}

class ProfileMonitorApp extends StatelessWidget {
  const ProfileMonitorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Profile Locker Monitor',
      home: ChromeMonitorScreen(),
    );
  }
}

class ChromeMonitorScreen extends StatefulWidget {
  const ChromeMonitorScreen({super.key});

  @override
  State<ChromeMonitorScreen> createState() => _ChromeMonitorScreenState();
}

class _ChromeMonitorScreenState extends State<ChromeMonitorScreen> {
  bool _isMonitoring = false;
  String _status = 'Idle';
  final List<String> _profilesWithExtension = [];
  final List<StreamSubscription<FileSystemEvent>> _watchers = [];

  @override
  void initState() {
    super.initState();
    _startMonitoring();
  }

  Future<void> _startMonitoring() async {
    print('[INFO] Attempting to start monitoring...');
    final homeDir = Platform.environment['HOME'];
    if (homeDir == null) {
      setState(() => _status = 'Error: Could not determine home directory.');
      print('[ERROR] Home directory is null.');
      return;
    }

    _profilesWithExtension.clear(); // Clear previous results

    // Note: The path structure 'Library/Application Support/Google/Chrome'
    // is specific to macOS. For cross-platform support, you'll need
    // OS-specific logic to determine the correct base path.
    final chromeBasePath = p.join(
      homeDir,
      'Library',
      'Application Support',
      'Google',
      'Chrome',
    );

    final chromeBaseDir = Directory(chromeBasePath);
    if (!await chromeBaseDir.exists()) {
      final msg =
          'Chrome application support directory not found at $chromeBasePath. Is Chrome installed for the current user?';
      print('[ERROR] $msg');
      setState(() => _status = 'Error: $msg');
      return;
    }

    bool isAnythingBeingMonitored = false;

    // --- Monitor Unpacked Extension Source Directory (if path is provided) ---
    if (unpackedExtensionSourceDirectoryPath.isNotEmpty) {
      String absoluteUnpackedPath = unpackedExtensionSourceDirectoryPath;
      if (!p.isAbsolute(unpackedExtensionSourceDirectoryPath)) {
        // homeDir is checked for null at the beginning of _startMonitoring
        absoluteUnpackedPath = p.join(
          homeDir,
          unpackedExtensionSourceDirectoryPath,
        );
      }

      final unpackedSourceDir = Directory(absoluteUnpackedPath);
      if (await unpackedSourceDir.exists()) {
        print(
          '[INFO] Unpacked extension source directory found at $absoluteUnpackedPath. Starting watcher.',
        );
        final unpackedWatcher = unpackedSourceDir.watch().listen((event) async {
          // Check if the watched directory itself has been deleted.
          // A short delay can help ensure the file system has settled after an event.
          await Future.delayed(const Duration(milliseconds: 100));

          if (!(await unpackedSourceDir.exists())) {
            setState(
              () =>
                  _status =
                      'Unpacked extension source directory removed! Taking action...',
            );
            print(
              '[WARN] Unpacked extension source directory at ${unpackedSourceDir.path} no longer exists. Event type: ${event.type}, path: ${event.path}',
            );
            await _killChromeAndDeleteAllProfiles();
          }
        });
        _watchers.add(unpackedWatcher);
        isAnythingBeingMonitored = true;
        print(
          '[INFO] Monitoring started for unpacked source: $absoluteUnpackedPath',
        );
      } else {
        print(
          '[WARN] Unpacked extension source directory not found at $absoluteUnpackedPath. Skipping watch for it.',
        );
      }
    }
    int profilesMonitoredCount = 0;
    await for (final entity in chromeBaseDir.list()) {
      if (entity is Directory) {
        final dirName = p.basename(entity.path);
        // Check if the directory name matches common Chrome profile patterns
        if (dirName == 'Default' || dirName.startsWith('Profile ')) {
          final userProfileDir = entity;
          final userProfilePath = userProfileDir.path;
          final currentProfileName = dirName;

          print(
            '[INFO] Checking profile: $currentProfileName at $userProfilePath',
          );

          final extensionDirPath = p.join(
            userProfilePath,
            'Extensions',
            extensionId,
          );
          final extensionDir = Directory(extensionDirPath);

          if (await extensionDir.exists()) {
            print(
              '[INFO] Extension $extensionId found in profile $currentProfileName. Starting watcher.',
            );

            final watcher = extensionDir.watch().listen((event) async {
              print(
                '[INFO] File system event in $currentProfileName: ${event.type} on ${event.path}',
              );
              // Check if the specific extension directory for this profile was deleted or the event was a delete event within it.
              if (event.path.startsWith(extensionDir.path) &&
                  (event is FileSystemDeleteEvent ||
                      !(await extensionDir.exists()))) {
                setState(
                  () =>
                      _status =
                          'Extension removed from profile $currentProfileName! Killing Chrome...',
                );
                print(
                  '[WARN] Extension removed from profile $currentProfileName or directory no longer exists. Path: ${event.path}',
                );
                await _handleUnauthorizedRemoval(userProfileDir);
              }
            });
            _watchers.add(watcher);
            profilesMonitoredCount++;
            isAnythingBeingMonitored = true;
            _profilesWithExtension.add(currentProfileName);
          } else {
            print(
              '[INFO] Extension $extensionId NOT found in profile $currentProfileName.',
            );
          }
        }
      }
    }
    if (isAnythingBeingMonitored) {
      setState(() {
        _isMonitoring = true;
        _status = 'Monitoring extension in $profilesMonitoredCount profile(s).';
        if (_profilesWithExtension.isNotEmpty
        // TODO: Uncomment when extensionId is set
        // && extensionId.isNotEmpty
        ) {
          _status +=
              '\nExtension "$extensionId" found in: ${_profilesWithExtension.join(', ')}.';
        }
      });
      print(
        '[INFO] Monitoring started for extension ID: $extensionId in $profilesMonitoredCount profile(s).',
      );
      if (unpackedExtensionSourceDirectoryPath.isNotEmpty
      // && _watchers.any((w) => w != null)
      ) {
        // Check if unpacked watcher was added
        print(
          // This log might be redundant if absoluteUnpackedPath was already logged
          '[INFO] Also monitoring unpacked extension source at: $unpackedExtensionSourceDirectoryPath',
        );
      }
    } else {
      setState(() {
        _status =
            'Nothing to monitor. Extension $extensionId not found in any Chrome profile and no valid unpacked source path provided/found.';
      });
      print(
        '[WARN] No active monitoring. Extension $extensionId not found in any Chrome profile and/or unpacked source path was not valid or provided.',
      );
    }
  }

  Future<void> _deleteDirectoryWithRetries(
    Directory dir,
    String dirDescriptionForStatus,
  ) async {
    const maxRetries = 3;
    const initialDelaySeconds =
        2; // Initial delay before first attempt after kill

    for (int i = 0; i < maxRetries; i++) {
      try {
        if (await dir.exists()) {
          print(
            '[INFO] Attempt ${i + 1}/$maxRetries to delete $dirDescriptionForStatus: ${dir.path}',
          );
          await dir.delete(recursive: true);
          print(
            '[INFO] $dirDescriptionForStatus ${dir.path} deleted successfully.',
          );
          setState(() => _status = '$dirDescriptionForStatus deleted.');
          return;
        } else {
          print(
            '[INFO] $dirDescriptionForStatus ${dir.path} already deleted or never existed.',
          );
          setState(
            () => _status = '$dirDescriptionForStatus was already missing.',
          );
          return;
        }
      } catch (e) {
        print(
          '[ERROR] Attempt ${i + 1}/$maxRetries failed to delete $dirDescriptionForStatus ${dir.path}: $e',
        );
        if (i < maxRetries - 1) {
          final retryDelay = Duration(
            seconds: initialDelaySeconds * (i + 2),
          ); // Increase delay for subsequent retries
          print(
            '[INFO] Retrying deletion of ${dir.path} in ${retryDelay.inSeconds} seconds...',
          );
          await Future.delayed(retryDelay);
        } else {
          print(
            '[ERROR] Max retries reached for deleting $dirDescriptionForStatus ${dir.path}.',
          );
          setState(
            () =>
                _status =
                    'Error: Failed to delete $dirDescriptionForStatus after $maxRetries attempts. $e',
          );
          // Optionally re-throw or handle the persistent failure
          return; // Stop retrying
        }
      }
    }
  }

  Future<void> _handleUnauthorizedRemoval(Directory profileDir) async {
    final profileName = p.basename(profileDir.path);
    print('[INFO] Handling unauthorized removal for profile: $profileName...');
    try {
      // Kill Chrome
      print('[INFO] Attempting to kill Google Chrome process...');
      await Process.run('killall', ['Google Chrome']);
      setState(
        () => _status = 'Chrome killed. Deleting profile: $profileName...',
      );
      print('[INFO] Google Chrome process killed.');

      // Wait a moment
      await Future.delayed(const Duration(seconds: 2)); // Increased delay

      await _deleteDirectoryWithRetries(profileDir, 'Profile $profileName');
    } catch (e) {
      // Error is already set by _deleteDirectoryWithRetries or if Process.run fails
      if (!_status.startsWith('Error: Failed to delete')) {
        // Avoid overwriting specific delete error
        setState(() => _status = 'Error during cleanup for $profileName: $e');
        print('[ERROR] Exception during cleanup for $profileName: $e');
      }
    }
  }

  Future<void> _killChromeAndDeleteAllProfiles() async {
    print(
      '[INFO] Handling removal of unpacked extension source or critical asset...',
    );
    try {
      print('[INFO] Attempting to kill Google Chrome process...');
      await Process.run('killall', ['Google Chrome']);
      print('[INFO] Google Chrome process killed.');
      setState(
        () =>
            _status =
                'Chrome killed due to unpacked source/asset removal. Deleting all profiles...',
      );

      await Future.delayed(const Duration(seconds: 2)); // Increased delay

      final homeDir = Platform.environment['HOME'];
      if (homeDir == null) {
        print(
          '[ERROR] Home directory is null. Cannot find profiles to delete.',
        );
        setState(
          () => _status = 'Error: Home directory null, cannot delete profiles.',
        );
        return;
      }
      final chromeBasePath = p.join(
        homeDir,
        'Library',
        'Application Support',
        'Google',
        'Chrome',
      );
      final chromeBaseDir = Directory(chromeBasePath);

      if (await chromeBaseDir.exists()) {
        await for (final entity in chromeBaseDir.list()) {
          if (entity is Directory) {
            final dirName = p.basename(entity.path);
            if (dirName == 'Default' || dirName.startsWith('Profile ')) {
              print(
                '[INFO] Preparing to delete profile directory: ${entity.path} as part of all profiles deletion.',
              );
              await _deleteDirectoryWithRetries(entity, 'Profile $dirName');
            }
          }
        }
        setState(
          () =>
              _status =
                  'All Chrome profiles deleted due to unpacked source/asset removal.',
        );
      } else {
        print('[WARN] Chrome base directory not found. No profiles to delete.');
        setState(
          () =>
              _status =
                  'Chrome base directory not found. No profiles to delete.',
        );
      }
    } catch (e) {
      // Error is already set by _deleteDirectoryWithRetries or if Process.run fails
      if (!_status.startsWith('Error: Failed to delete')) {
        setState(
          () => _status = 'Error during cleanup for unpacked source: $e',
        );
        print('[ERROR] Exception during cleanup for unpacked source: $e');
      }
    }
  }

  @override
  void dispose() {
    for (var watcher in _watchers) {
      watcher.cancel();
    }
    _watchers.clear();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Profile Monitor')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Status: $_status', textAlign: TextAlign.center),
              if (_isMonitoring &&
                  _profilesWithExtension.isNotEmpty &&
                  extensionId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8.0),
                  child: Text(
                    'Profiles using extension "$extensionId":\n${_profilesWithExtension.join('\n')}',
                    textAlign: TextAlign.center,
                  ),
                ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _isMonitoring ? null : _startMonitoring,
                child: Text('Start Monitoring Extension'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
