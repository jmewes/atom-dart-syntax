library atom.flutter.flutter_launch;

import 'dart:async';

import 'package:logging/logging.dart';

import '../atom.dart';
import '../atom_utils.dart';
import '../debug/debugger.dart';
import '../debug/observatory_debugger.dart' show ObservatoryDebugger;
import '../launch/launch.dart';
import '../process.dart';
import '../projects.dart';
import '../state.dart';
import 'flutter_sdk.dart';

final Logger _logger = new Logger('atom.flutter_launch');

const String _toolName = 'flutter';

FlutterSdkManager _flutterSdk = deps[FlutterSdkManager];

class FlutterLaunchType extends LaunchType {
  static void register(LaunchManager manager) =>
      manager.registerLaunchType(new FlutterLaunchType());

  _LaunchInstance _lastLaunch;

  FlutterLaunchType() : super('flutter');

  bool canLaunch(String path) {
    DartProject project = projectManager.getProjectFor(path);
    if (project == null) return false;

    if (!_flutterSdk.hasSdk) return false;

    String relPath = relativize(project.path, path);
    return relPath == 'lib${separator}main.dart';
  }

  List<String> getLaunchablesFor(DartProject project) {
    // TODO: Return other main files?
    File file = project.directory.getFile('lib${separator}main.dart');
    return file.existsSync() ? [file.path] : [];
  }

  Future<Launch> performLaunch(LaunchManager manager, LaunchConfiguration configuration) {
    String path = configuration.primaryResource;
    DartProject project = projectManager.getProjectFor(path);
    if (project == null) return new Future.error("File not in a Dart project.");

    if (!_flutterSdk.hasSdk) {
      _flutterSdk.showInstallationInfo();
      return new Future.error("Unable to launch ${configuration.shortResourceName}; "
        " no Flutter SDK found.");
    }

    return _killLastLaunch().then((_) {
      _lastLaunch = new _LaunchInstance(project, configuration, this);
      return _lastLaunch.launch();
    });
  }

  Future _killLastLaunch() {
    if (_lastLaunch == null) return new Future.value();
    Launch launch = _lastLaunch._launch;
    return launch.isTerminated ? new Future.value() : launch.kill();
  }
}

class _LaunchInstance {
  final DartProject project;

  Launch _launch;
  ProcessRunner _runner;
  bool _withDebug;

  _LaunchInstance(this.project, LaunchConfiguration configuration,
      LaunchType launchType) {
    _launch = new Launch(
        launchManager,
        launchType,
        configuration,
        'lib${separator}main.dart',
        killHandler: _kill);
    launchManager.addLaunch(_launch);
    _launch.pipeStdio('[${project.path}] ${_toolName} start\n', highlight: true);

    _withDebug = configuration.debug ?? debugDefault;
    if (!LaunchManager.launchWithDebugging()) _withDebug = false;
  }

  Future<Launch> launch() async {
    FlutterTool flutter = _flutterSdk.sdk.flutterTool;

    // Chain together both 'flutter start' and 'flutter logs'.
    // TODO: Add a user option for `--checked`.
    _runner = _flutter(flutter, ['start'], project.path);
    _runner.execStreaming();
    _runner.onStdout.listen((str) => _launch.pipeStdio(str));
    _runner.onStderr.listen((str) => _launch.pipeStdio(str, error: true));

    int code = await _runner.onExit;
    if (code == 0) {
      int port = 8181;
      _launch.servicePort.value = port;

      if (_withDebug) {
        // TODO: Figure out this timing (https://github.com/flutter/tools/issues/110).
        new Future.delayed(new Duration(seconds: 4), () {
          FlutterUriTranslator translator =
              new FlutterUriTranslator(_launch.project?.path);
          Future f = ObservatoryDebugger.connect(_launch, 'localhost', port,
              isolatesStartPaused: false,
              uriTranslator: translator);
          f.catchError((e) {
            _launch.pipeStdio(
                'Unable to connect to the observatory (port ${port}).\n',
                error: true);
          });
        });
      }

      // Chain 'flutter logs'.
      _runner = _flutter(flutter, ['logs', '--clear'], project.path);
      _runner.execStreaming();
      _runner.onStdout.listen((str) => _launch.pipeStdio(str));
      _runner.onStderr.listen((str) => _launch.pipeStdio(str, error: true));

      // Don't return the future here.
      _runner.onExit.then((code) => _launch.launchTerminated(code));
    } else {
      _launch.launchTerminated(code);
    }

    return _launch;
  }

  Future _kill() {
    if (_runner == null) {
      _launch.launchTerminated(1);
      return new Future.value();
    } else {
      return _runner.kill();
    }
  }
}

ProcessRunner _flutter(FlutterTool flutter, List<String> args, String cwd) {
  return flutter.runRaw(args, cwd: cwd, startProcess: false);
}

class FlutterUriTranslator implements UriTranslator {
  static const _packagesPrefix = 'packages/';
  static const _packagePrefix = 'package:';

  final String root;
  final String prefix;

  String _rootPrefix;

  FlutterUriTranslator(this.root, {this.prefix: 'http://localhost:9888/'}) {
    _rootPrefix = new Uri.directory(root, windows: isWindows).toString();
  }

  String targetToClient(String str) {
    String result = _targetToClient(str);
    _logger.finer('targetToClient ${str} ==> ${result}');
    return result;
  }

  String _targetToClient(String str) {
    if (str.startsWith(prefix)) {
      str = str.substring(prefix.length);

      if (str.startsWith(_packagesPrefix)) {
        // Convert packages/ prefix to package: one.
        return _packagePrefix + str.substring(_packagesPrefix.length);
      } else {
        // Return files relative to the starting project.
        return '${_rootPrefix}${str}';
      }
    } else {
      return str;
    }
  }

  String clientToTarget(String str) {
    String result = _clientToTarget(str);
    _logger.finer('clientToTarget ${str} ==> ${result}');
    return result;
  }

  String _clientToTarget(String str) {
    if (str.startsWith(_packagePrefix)) {
      // Convert package: prefix to packages/ one.
      return prefix + _packagesPrefix + str.substring(_packagePrefix.length);
    } else if (str.startsWith(_rootPrefix)) {
      // Convert file:///foo/bar/lib/main.dart to http://.../lib/main.dart.
      return prefix + str.substring(_rootPrefix.length);
    } else {
      return str;
    }
  }
}
