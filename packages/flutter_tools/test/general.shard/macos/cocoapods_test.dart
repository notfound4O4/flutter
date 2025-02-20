// Copyright 2014 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

// @dart = 2.8

import 'package:file/file.dart';
import 'package:file/memory.dart';
import 'package:flutter_tools/src/base/io.dart';
import 'package:flutter_tools/src/base/logger.dart';
import 'package:flutter_tools/src/base/platform.dart';
import 'package:flutter_tools/src/build_info.dart';
import 'package:flutter_tools/src/cache.dart';
import 'package:flutter_tools/src/ios/xcodeproj.dart';
import 'package:flutter_tools/src/macos/cocoapods.dart';
import 'package:flutter_tools/src/plugins.dart';
import 'package:flutter_tools/src/project.dart';
import 'package:flutter_tools/src/reporting/reporting.dart';
import 'package:test/fake.dart';

import '../../src/common.dart';
import '../../src/context.dart';
import '../../src/fake_process_manager.dart';

typedef InvokeProcess = Future<ProcessResult> Function();

void main() {
  FileSystem fileSystem;
  FakeProcessManager fakeProcessManager;
  FlutterProject projectUnderTest;
  CocoaPods cocoaPodsUnderTest;
  BufferLogger logger;
  TestUsage usage;

  void pretendPodVersionFails() {
    fakeProcessManager.addCommand(
      const FakeCommand(
        command: <String>['pod', '--version'],
        exitCode: 1,
      ),
    );
  }

  void pretendPodVersionIs(String versionText) {
    fakeProcessManager.addCommand(
      FakeCommand(
        command: const <String>['pod', '--version'],
        stdout: versionText,
      ),
    );
  }

  void podsIsInHomeDir() {
    fileSystem.directory(fileSystem.path.join(
      '.cocoapods',
      'repos',
      'master',
    )).createSync(recursive: true);
  }

  setUp(() async {
    Cache.flutterRoot = 'flutter';
    fileSystem = MemoryFileSystem.test();
    fakeProcessManager = FakeProcessManager.list(<FakeCommand>[]);
    logger = BufferLogger.test();
    projectUnderTest = FlutterProject.fromDirectory(fileSystem.directory('project'));
    projectUnderTest.ios.xcodeProject.createSync(recursive: true);
    projectUnderTest.macos.xcodeProject.createSync(recursive: true);
    usage = TestUsage();
    cocoaPodsUnderTest = CocoaPods(
      fileSystem: fileSystem,
      processManager: fakeProcessManager,
      logger: logger,
      platform: FakePlatform(operatingSystem: 'macos'),
      xcodeProjectInterpreter: FakeXcodeProjectInterpreter(),
      usage: usage,
    );
    fileSystem.file(fileSystem.path.join(
      Cache.flutterRoot, 'packages', 'flutter_tools', 'templates', 'cocoapods', 'Podfile-ios-objc',
    ))
        ..createSync(recursive: true)
        ..writeAsStringSync('Objective-C iOS podfile template');
    fileSystem.file(fileSystem.path.join(
      Cache.flutterRoot, 'packages', 'flutter_tools', 'templates', 'cocoapods', 'Podfile-ios-swift',
    ))
        ..createSync(recursive: true)
        ..writeAsStringSync('Swift iOS podfile template');
    fileSystem.file(fileSystem.path.join(
      Cache.flutterRoot, 'packages', 'flutter_tools', 'templates', 'cocoapods', 'Podfile-macos',
    ))
        ..createSync(recursive: true)
        ..writeAsStringSync('macOS podfile template');
  });

  void pretendPodIsNotInstalled() {
    fakeProcessManager.addCommand(
      const FakeCommand(
        command: <String>['which', 'pod'],
        exitCode: 1,
      ),
    );
  }

  void pretendPodIsBroken() {
    fakeProcessManager.addCommands(<FakeCommand>[
      // it is present
      const FakeCommand(
        command: <String>['which', 'pod'],
      ),
      // but is not working
      const FakeCommand(
        command: <String>['pod', '--version'],
        exitCode: 1,
      ),
    ]);
  }

  void pretendPodIsInstalled() {
    fakeProcessManager.addCommands(<FakeCommand>[
      const FakeCommand(
        command: <String>['which', 'pod'],
      ),
    ]);
  }

  group('Evaluate installation', () {
    testWithoutContext('detects not installed, if pod exec does not exist', () async {
      pretendPodIsNotInstalled();
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.notInstalled);
    });

    testWithoutContext('detects not installed, if pod is installed but version fails', () async {
      pretendPodIsInstalled();
      pretendPodVersionFails();
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.brokenInstall);
    });

    testWithoutContext('detects installed', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('0.0.1');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, isNot(CocoaPodsStatus.notInstalled));
    });

    testWithoutContext('detects unknown version', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('Plugin loaded.\n1.5.3');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.unknownVersion);
    });

    testWithoutContext('detects below minimum version', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.6.0');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.belowMinimumVersion);
    });

    testWithoutContext('detects below recommended version', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.9.0');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.belowRecommendedVersion);
    });

    testWithoutContext('detects at recommended version', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.recommended);
    });

    testWithoutContext('detects above recommended version', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.1');
      expect(await cocoaPodsUnderTest.evaluateCocoaPodsInstallation, CocoaPodsStatus.recommended);
    });
  });

  group('Setup Podfile', () {
    testWithoutContext('creates objective-c Podfile when not present', () async {
      await cocoaPodsUnderTest.setupPodfile(projectUnderTest.ios);

      expect(projectUnderTest.ios.podfile.readAsStringSync(), 'Objective-C iOS podfile template');
    });

    testWithoutContext('creates swift Podfile if swift', () async {
      final FakeXcodeProjectInterpreter fakeXcodeProjectInterpreter = FakeXcodeProjectInterpreter(buildSettings: <String, String>{
        'SWIFT_VERSION': '5.0',
      });
      final CocoaPods cocoaPodsUnderTest = CocoaPods(
        fileSystem: fileSystem,
        processManager: fakeProcessManager,
        logger: logger,
        platform: FakePlatform(operatingSystem: 'macos'),
        xcodeProjectInterpreter: fakeXcodeProjectInterpreter,
        usage: usage,
      );

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await cocoaPodsUnderTest.setupPodfile(project.ios);

      expect(projectUnderTest.ios.podfile.readAsStringSync(), 'Swift iOS podfile template');
    });

    testWithoutContext('creates macOS Podfile when not present', () async {
      projectUnderTest.macos.xcodeProject.createSync(recursive: true);
      await cocoaPodsUnderTest.setupPodfile(projectUnderTest.macos);

      expect(projectUnderTest.macos.podfile.readAsStringSync(), 'macOS podfile template');
    });

    testWithoutContext('does not recreate Podfile when already present', () async {
      projectUnderTest.ios.podfile..createSync()..writeAsStringSync('Existing Podfile');

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await cocoaPodsUnderTest.setupPodfile(project.ios);

      expect(projectUnderTest.ios.podfile.readAsStringSync(), 'Existing Podfile');
    });

    testWithoutContext('does not create Podfile when we cannot interpret Xcode projects', () async {
      final CocoaPods cocoaPodsUnderTest = CocoaPods(
        fileSystem: fileSystem,
        processManager: fakeProcessManager,
        logger: logger,
        platform: FakePlatform(operatingSystem: 'macos'),
        xcodeProjectInterpreter: FakeXcodeProjectInterpreter(isInstalled: false),
        usage: usage,
      );

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await cocoaPodsUnderTest.setupPodfile(project.ios);

      expect(projectUnderTest.ios.podfile.existsSync(), false);
    });

    testWithoutContext('includes Pod config in xcconfig files, if not present', () async {
      projectUnderTest.ios.podfile..createSync()..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.xcodeConfigFor('Debug')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing debug config');
      projectUnderTest.ios.xcodeConfigFor('Release')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing release config');

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await cocoaPodsUnderTest.setupPodfile(project.ios);

      final String debugContents = projectUnderTest.ios.xcodeConfigFor('Debug').readAsStringSync();
      expect(debugContents, contains(
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"\n'));
      expect(debugContents, contains('Existing debug config'));
      final String releaseContents = projectUnderTest.ios.xcodeConfigFor('Release').readAsStringSync();
      expect(releaseContents, contains(
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"\n'));
      expect(releaseContents, contains('Existing release config'));
    });

    testWithoutContext('does not include Pod config in xcconfig files, if legacy non-option include present', () async {
      projectUnderTest.ios.podfile..createSync()..writeAsStringSync('Existing Podfile');

      const String legacyDebugInclude = '#include "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig';
      projectUnderTest.ios.xcodeConfigFor('Debug')
        ..createSync(recursive: true)
        ..writeAsStringSync(legacyDebugInclude);
      const String legacyReleaseInclude = '#include "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig';
      projectUnderTest.ios.xcodeConfigFor('Release')
        ..createSync(recursive: true)
        ..writeAsStringSync(legacyReleaseInclude);

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await cocoaPodsUnderTest.setupPodfile(project.ios);

      final String debugContents = projectUnderTest.ios.xcodeConfigFor('Debug').readAsStringSync();
      // Redundant contains check, but this documents what we're testing--that the optional
      // #include? doesn't get written in addition to the previous style #include.
      expect(debugContents, isNot(contains('#include?')));
      expect(debugContents, equals(legacyDebugInclude));
      final String releaseContents = projectUnderTest.ios.xcodeConfigFor('Release').readAsStringSync();
      expect(releaseContents, isNot(contains('#include?')));
      expect(releaseContents, equals(legacyReleaseInclude));
    });
  });

  group('Update xcconfig', () {
    testUsingContext('includes Pod config in xcconfig files, if the user manually added Pod dependencies without using Flutter plugins', () async {
      fileSystem.file(fileSystem.path.join('project', 'foo', '.packages'))
        ..createSync(recursive: true)
        ..writeAsStringSync('\n');
      projectUnderTest.ios.podfile..createSync()..writeAsStringSync('Custom Podfile');
      projectUnderTest.ios.podfileLock..createSync()..writeAsStringSync('Podfile.lock from user executed `pod install`');
      projectUnderTest.packagesFile..createSync()..writeAsStringSync('');
      projectUnderTest.ios.xcodeConfigFor('Debug')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing debug config');
      projectUnderTest.ios.xcodeConfigFor('Release')
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing release config');

      final FlutterProject project = FlutterProject.fromDirectoryTest(fileSystem.directory('project'));
      await injectPlugins(project, iosPlatform: true);

      final String debugContents = projectUnderTest.ios.xcodeConfigFor('Debug').readAsStringSync();
      expect(debugContents, contains(
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.debug.xcconfig"\n'));
      expect(debugContents, contains('Existing debug config'));
      final String releaseContents = projectUnderTest.ios.xcodeConfigFor('Release').readAsStringSync();
      expect(releaseContents, contains(
          '#include? "Pods/Target Support Files/Pods-Runner/Pods-Runner.release.xcconfig"\n'));
      expect(releaseContents, contains('Existing release config'));
    }, overrides: <Type, Generator>{
      FileSystem: () => fileSystem,
      ProcessManager: () => FakeProcessManager.any(),
    });
  });

  group('Process pods', () {
    setUp(() {
      podsIsInHomeDir();
    });

    testWithoutContext('throwsToolExit if CocoaPods is not installed', () async {
      pretendPodIsNotInstalled();
      projectUnderTest.ios.podfile.createSync();
      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'CocoaPods not installed or not in valid state'));
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
      expect(fakeProcessManager, hasNoRemainingExpectations);
    });

    testWithoutContext('throwsToolExit if CocoaPods install is broken', () async {
      pretendPodIsBroken();
      projectUnderTest.ios.podfile.createSync();
      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'CocoaPods not installed or not in valid state'));
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
      expect(fakeProcessManager, hasNoRemainingExpectations);
    });

    testWithoutContext('exits if Podfile creates the Flutter engine symlink', () async {
      fileSystem.file(fileSystem.path.join('project', 'ios', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('Existing Podfile');

      final Directory symlinks = projectUnderTest.ios.symlinks
        ..createSync(recursive: true);
      symlinks.childLink('flutter').createSync('cache');

      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'Podfile is out of date'));
      expect(fakeProcessManager, hasNoRemainingExpectations);
    });

    testWithoutContext('exits if iOS Podfile parses .flutter-plugins', () async {
      fileSystem.file(fileSystem.path.join('project', 'ios', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('plugin_pods = parse_KV_file(\'../.flutter-plugins\')');

      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'Podfile is out of date'));
      expect(fakeProcessManager, hasNoRemainingExpectations);
    });

    testWithoutContext('prints warning if macOS Podfile parses .flutter-plugins', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
        ),
      );

      fileSystem.file(fileSystem.path.join('project', 'macos', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('plugin_pods = parse_KV_file(\'../.flutter-plugins\')');

      await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.macos,
        buildMode: BuildMode.debug,
      );

      expect(logger.errorText, contains('Warning: Podfile is out of date'));
      expect(logger.errorText, contains('rm macos/Podfile'));
      expect(fakeProcessManager, hasNoRemainingExpectations);
    });

    testWithoutContext('throws, if Podfile is missing.', () async {
      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'Podfile missing'));
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('throws, if specs repo is outdated.', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      fileSystem.file(fileSystem.path.join('project', 'ios', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('Existing Podfile');

      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{
            'COCOAPODS_DISABLE_STATS': 'true',
            'LANG': 'en_US.UTF-8',
          },
          exitCode: 1,
          stdout: '''
[!] Unable to satisfy the following requirements:

- `Firebase/Auth` required by `Podfile`
- `Firebase/Auth (= 4.0.0)` required by `Podfile.lock`

None of your spec sources contain a spec satisfying the dependencies: `Firebase/Auth, Firebase/Auth (= 4.0.0)`.

You have either:
 * out-of-date source repos which you can update with `pod repo update` or with `pod install --repo-update`.
 * mistyped the name or version.
 * not added the source repo that hosts the Podspec to your Podfile.

Note: as of CocoaPods 1.0, `pod repo update` does not happen on `pod install` by default.''',
        ),
      );

      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit());
      expect(
        logger.errorText,
        contains(
            "CocoaPods's specs repository is too out-of-date to satisfy dependencies"),
      );
    });

    testWithoutContext('ffi failure on ARM macOS prompts gem install', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      fileSystem.file(fileSystem.path.join('project', 'ios', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('Existing Podfile');

      fakeProcessManager.addCommands(<FakeCommand>[
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{
            'COCOAPODS_DISABLE_STATS': 'true',
            'LANG': 'en_US.UTF-8',
          },
          exitCode: 1,
          stdout: 'LoadError - dlsym(0x7fbbeb6837d0, Init_ffi_c): symbol not found - /Library/Ruby/Gems/2.6.0/gems/ffi-1.13.1/lib/ffi_c.bundle',
        ),
        const FakeCommand(
          command: <String>['which', 'sysctl'],
        ),
        const FakeCommand(
          command: <String>['sysctl', 'hw.optional.arm64'],
          stdout: 'hw.optional.arm64: 1',
        ),
      ]);

      await expectToolExitLater(
        cocoaPodsUnderTest.processPods(
          xcodeProject: projectUnderTest.ios,
          buildMode: BuildMode.debug,
        ),
        equals('Error running pod install'),
      );
      expect(
        logger.errorText,
        contains('set up CocoaPods for ARM macOS'),
      );
      expect(usage.events, contains(const TestUsageEvent('pod-install-failure', 'arm-ffi')));
    });

    testWithoutContext('ffi failure on x86 macOS does not prompt gem install', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      fileSystem.file(fileSystem.path.join('project', 'ios', 'Podfile'))
        ..createSync()
        ..writeAsStringSync('Existing Podfile');

      fakeProcessManager.addCommands(<FakeCommand>[
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{
            'COCOAPODS_DISABLE_STATS': 'true',
            'LANG': 'en_US.UTF-8',
          },
          exitCode: 1,
          stderr: 'LoadError - dlsym(0x7fbbeb6837d0, Init_ffi_c): symbol not found - /Library/Ruby/Gems/2.6.0/gems/ffi-1.13.1/lib/ffi_c.bundle',
        ),
        const FakeCommand(
          command: <String>['which', 'sysctl'],
        ),
        const FakeCommand(
          command: <String>['sysctl', 'hw.optional.arm64'],
          exitCode: 1,
        ),
      ]);

      // Capture Usage.test() events.
      final StringBuffer buffer =
      await capturedConsolePrint(() => expectToolExitLater(
        cocoaPodsUnderTest.processPods(
          xcodeProject: projectUnderTest.ios,
          buildMode: BuildMode.debug,
        ),
        equals('Error running pod install'),
      ));
      expect(
        logger.errorText,
        isNot(contains('ARM macOS')),
      );
      expect(buffer.isEmpty, true);
    });

    testWithoutContext('run pod install, if Podfile.lock is missing', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing lock file.');

      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(didInstall, isTrue);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('runs iOS pod install, if Manifest.lock is missing', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(didInstall, isTrue);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('runs macOS pod install, if Manifest.lock is missing', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.macos.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.macos.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/macos',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.macos,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(didInstall, isTrue);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('runs pod install, if Manifest.lock different from Podspec.lock', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Different lock file.');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(didInstall, isTrue);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('runs pod install, if flutter framework changed', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing lock file.');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: true,
      );
      expect(didInstall, isTrue);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('runs pod install, if Podfile.lock is older than Podfile', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing lock file.');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      projectUnderTest.ios.podfile
        .writeAsStringSync('Updated Podfile');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
        ),
      );
      await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('skips pod install, if nothing changed', () async {
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing lock file.');
      final bool didInstall = await cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
        dependenciesChanged: false,
      );
      expect(didInstall, isFalse);
      expect(fakeProcessManager.hasRemainingExpectations, isFalse);
    });

    testWithoutContext('a failed pod install deletes Pods/Manifest.lock', () async {
      pretendPodIsInstalled();
      pretendPodVersionIs('1.10.0');
      projectUnderTest.ios.podfile
        ..createSync()
        ..writeAsStringSync('Existing Podfile');
      projectUnderTest.ios.podfileLock
        ..createSync()
        ..writeAsStringSync('Existing lock file.');
      projectUnderTest.ios.podManifestLock
        ..createSync(recursive: true)
        ..writeAsStringSync('Existing lock file.');
      fakeProcessManager.addCommand(
        const FakeCommand(
          command: <String>['pod', 'install', '--verbose'],
          workingDirectory: 'project/ios',
          environment: <String, String>{'COCOAPODS_DISABLE_STATS': 'true', 'LANG': 'en_US.UTF-8'},
          exitCode: 1,
        ),
      );

      await expectLater(cocoaPodsUnderTest.processPods(
        xcodeProject: projectUnderTest.ios,
        buildMode: BuildMode.debug,
      ), throwsToolExit(message: 'Error running pod install'));
      expect(projectUnderTest.ios.podManifestLock.existsSync(), isFalse);
    });
  });
}

class FakeXcodeProjectInterpreter extends Fake implements XcodeProjectInterpreter {
  FakeXcodeProjectInterpreter({this.isInstalled = true, this.buildSettings = const <String, String>{}});

  @override
  final bool isInstalled;

  @override
  Future<Map<String, String>> getBuildSettings(
    String projectPath, {
    String scheme,
    Duration timeout = const Duration(minutes: 1),
  }) async => buildSettings;

  final Map<String, String> buildSettings;
}
