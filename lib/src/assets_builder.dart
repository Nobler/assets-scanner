// Copyright (C) 2020 littlegnal
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'package:meta/meta.dart';

import 'package:build/build.dart';
import 'package:glob/glob.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

class _AssetsScannerOptions {
  const _AssetsScannerOptions._({
    this.path = 'lib',
    this.className = 'R',
    this.ignoreComment = false,
    this.namePattern,
  });

  factory _AssetsScannerOptions() => const _AssetsScannerOptions._();

  factory _AssetsScannerOptions.fromYamlMap(YamlMap map) {
    return _AssetsScannerOptions._(
        path: map['path'] as String? ?? 'lib',
        className: map['className'] as String? ?? 'R',
        ignoreComment: map['ignoreComment'] as bool? ?? false,
        namePattern: map['namePattern'] as String?);
  }

  /// The path where the `r.dart` file locate. Note that the `path` should be
  /// sub-path of `lib/`.
  final String path;

  /// The class name of the `r.dart`.
  final String className;

  /// Indicate the comments need to be generated or not. Note that the you can't
  /// preview the images assets if `ignoreComment` is `true`.
  final bool ignoreComment;

  /// The pattern should be matched for assets to be handled.
  /// If the pattern is kept with null, all assets will be handled.
  final String? namePattern;

  @override
  String toString() =>
      '_AssetsScannerOptions(path: $path, className: $className, ignoreComment: $ignoreComment)';
}

/// File header of generated file.
@visibleForOverriding
const String rFileHeader =
    '/// GENERATED BY assets_scanner. DO NOT MODIFY BY HAND.\n'
    '/// See more detail on https://github.com/nobler/assets-scanner.';

/// Ignore for file definition.
@visibleForOverriding
const ignoreForFile = '// ignore_for_file: '
    'always_put_control_body_on_new_line,'
    'always_specify_types,'
    'annotate_overrides,'
    'avoid_annotating_with_dynamic,'
    'avoid_as,'
    'avoid_catches_without_on_clauses,'
    'avoid_returning_this,'
    'lines_longer_than_80_chars,'
    'omit_local_variable_types,'
    'prefer_expression_function_bodies,'
    'sort_constructors_first,'
    'test_types_in_equals,'
    'unnecessary_const,'
    'unnecessary_new,'
    'public_member_api_docs,'
    'constant_identifier_names,'
    'prefer_double_quotes';

/// Borrow from https://github.com/dart-lang/sdk/blob/c3f96e863ff402be32aa7acf51ee05b7de0b9841/pkg/analyzer/lib/src/lint/util.dart#L15
final _identifier = RegExp(r'^([(_|$)a-zA-Z]+([_a-zA-Z0-9])*)$');

final _identifierStart = RegExp(r'^([(_|$)a-zA-Z]+)');

final _invalidIdentifierCharecaters = RegExp(r'[^_a-zA-Z0-9]+');

const _propertyNamePrefix = 'r_';

/// [AssetsBuilder] will get the assets path from `pubspec.yaml` and generate
/// a `r.dart` with `const` properties of assets path by default. You can custom
/// it by adding an `assets_scanner_options.yaml` file, and the supported key
/// is same with [_AssetsScannerOptions]'s properties name.
class AssetsBuilder extends Builder {
  @override
  Map<String, List<String>> get buildExtensions {
    final options = _getOptions();
    var extensions = 'r.dart';
    if (options.path != 'lib' && options.path.startsWith('lib/')) {
      extensions = '${options.path.replaceFirst('lib/', '')}/$extensions';
    }
    // TODO(littlegnal): It's so wired that this works, but the `buildExtensions` here not
    // match the `build_extensions` in the `build.yaml` file. Need more research see
    // if it's a correct way.
    return {
      r'$lib$': ['$extensions']
    };
  }

  @override
  FutureOr<void> build(BuildStep buildStep) async {
    final pubspecYamlMap = await _createPubspecYampMap(buildStep);
    if (pubspecYamlMap?.isEmpty ?? true) return;

    final options = _getOptions();
    if (!options.path.startsWith('lib')) {
      log.severe(
          'The custom path in assets_scanner_options.yaml should be sub-path of lib/.');
      return;
    }

    final rClass =
        await _generateRFileContent(buildStep, pubspecYamlMap!, options);
    if (rClass.isEmpty) return;

    final dir = options.path.startsWith('lib') ? options.path : 'lib';
    final output = AssetId(buildStep.inputId.package, p.join(dir, 'r.dart'));
    await buildStep.writeAsString(output, rClass);
  }

  Future<String> _generateRFileContent(BuildStep buildStep,
      YamlMap pubspecYamlMap, _AssetsScannerOptions options) async {
    final assetPathsClass =
        await _createRClass(pubspecYamlMap, buildStep, options);

    final packageAssetPathsClass = _createPackageAssetsClass(pubspecYamlMap);

    final hasAnyPaths =
        assetPathsClass.isNotEmpty || packageAssetPathsClass.isNotEmpty;
    if (!hasAnyPaths) {
      return '';
    }

    final rFileContent = StringBuffer();
    if (hasAnyPaths) {
      rFileContent.writeln(rFileHeader);
    }
    if (assetPathsClass.isNotEmpty) {
      rFileContent.write(assetPathsClass.toString());
    }
    if (packageAssetPathsClass.isNotEmpty) {
      if (assetPathsClass.isNotEmpty) {
        rFileContent.writeln();
      }

      rFileContent.write(packageAssetPathsClass.toString());
    }

    return rFileContent.toString();
  }

  String _createPropertyName(String assetPath) {
    var propertyName = assetPath.substring(
        assetPath.indexOf('/') + 1, assetPath.lastIndexOf('.'));
    // On iOS it will create a .DS_Store file in assets folder which will
    // cause an empty property name, so we skip it.
    if (propertyName.isEmpty) return propertyName;

    if (_identifier.hasMatch(propertyName)) {
      // Ignore the parent path to make the property name shorter.
      propertyName = propertyName.replaceAll('/', '_');
    } else {
      final shouldAddPrefix = !_identifierStart.hasMatch(propertyName);

      propertyName = propertyName.replaceAllMapped(
        _invalidIdentifierCharecaters,
        (match) {
          return '_';
        },
      );

      if (shouldAddPrefix) {
        propertyName = _propertyNamePrefix + propertyName;
      }
    }

    return propertyName;
  }

  String _assetName(String assetPath) => assetPath.substring(
      assetPath.indexOf('/') + 1, assetPath.lastIndexOf('.'));

  bool _testNamePattern(String name, String? namePattern) =>
      namePattern == null || RegExp(namePattern).hasMatch(name);

  Future<String> _createRClass(YamlMap pubspecYamlMap, BuildStep buildStep,
      _AssetsScannerOptions options) async {
    final assetPaths =
        await _findAssetIdPathsFromFlutterAssetsList(buildStep, pubspecYamlMap);
    final assetPathsClass = StringBuffer();
    if (assetPaths.isNotEmpty) {
      // Create default asset paths class.
      assetPathsClass
        ..writeln('class ${options.className} {')
        ..writeln('  static const package = \'${buildStep.inputId.package}\';')
        ..writeln();
      for (final assetPath in assetPaths) {
        final propertyName = _createPropertyName(assetPath);

        if (propertyName.isNotEmpty &&
            _testNamePattern(_assetName(assetPath), options.namePattern)) {
          if (!options.ignoreComment) {
            assetPathsClass.writeln('  /// ![](${p.absolute(assetPath)})');
          }
          assetPathsClass
            ..writeln('  static const $propertyName = \'$assetPath\';')
            ..writeln();
        }
      }

      // ignore: cascade_invocations
      assetPathsClass
        ..writeln(
            '  /// Get the name with the path of a asset in assets folder by its file name(no suffix).')
        ..writeln('  /// Null will be returned if no assets found.')
        ..writeln('  static String? get(String fileName) {')
        ..writeln('    switch (fileName) {');

      final unfittedNames = <String>[];

      for (final assetPath in assetPaths) {
        final name = _assetName(assetPath);

        // ignore the .DS_Store file
        if (name.isEmpty) continue;

        if (!_testNamePattern(name, options.namePattern)) {
          unfittedNames.add(name);
          continue;
        }

        assetPathsClass
          ..writeln("      case '$name':")
          ..writeln("        return '$assetPath';");
      }

      if (unfittedNames.isNotEmpty) {
        assetPathsClass.writeln('      // unfitted names:');
        for (final name in unfittedNames) {
          assetPathsClass.writeln('      // $name');
        }
      }
      assetPathsClass..writeln('''
      default:
        return null;
    }
  }''')..writeln();

      // ignore: cascade_invocations
      assetPathsClass..writeln(ignoreForFile)..writeln('}');
    }

    return assetPathsClass.toString();
  }

  String _createPackageAssetsClass(YamlMap pubspecYamlMap) {
    final assetPaths = _getAssetsListFromPubspec(pubspecYamlMap);
    Set<String>? pubspecDependencies;
    Map<String, Map<String, String>>? packageAssetPaths;
    for (final assetPath in assetPaths) {
      // Handle the package assets, more detail about the directory structure:
      // https://flutter.dev/docs/development/ui/assets-and-images#bundling-of-package-assets
      if (assetPath.startsWith('packages')) {
        final assetPathSegments = assetPath.split('/');
        if (assetPathSegments.length >= 2) {
          pubspecDependencies ??= _getPackagesFromPubspec(pubspecYamlMap);
          final packageName = assetPathSegments[1];

          if (pubspecDependencies.contains(packageName)) {
            packageAssetPaths ??= {};
            final assetPathsOfPackge =
                packageAssetPaths.putIfAbsent(packageName, () => {});
            final actualAssetPath = assetPath.substring(
                // The length of `packages/<package-name>/`
                assetPath.indexOf(packageName) + packageName.length + 1);
            final propertyName = actualAssetPath
                .substring(0, actualAssetPath.lastIndexOf('.'))
                .replaceAll('/', '_');
            assetPathsOfPackge[propertyName] = actualAssetPath;
          }
        }
      }
    }

    final packageAssetPathsClass = StringBuffer();
    if (packageAssetPaths != null) {
      // Create package asset paths class.
      packageAssetPaths.forEach((packageName, assetPaths) {
        var className = '';
        if (packageName.contains('_')) {
          final tempSegments = packageName.split('_');
          for (final s in tempSegments) {
            className += (s.substring(0, 1).toUpperCase() + s.substring(1));
          }
        } else {
          className = packageName.substring(0, 1).toUpperCase() +
              packageName.substring(1);
        }
        packageAssetPathsClass
          ..writeln('class $className {')
          ..writeln('  static const package = \'$packageName\';')
          ..writeln();
        assetPaths.forEach((propertyName, assetPath) {
          packageAssetPathsClass
            ..writeln('  static const $propertyName = \'$assetPath\';')
            ..writeln();
        });
        packageAssetPathsClass..writeln(ignoreForFile)..writeln('}');
      });
    }

    return packageAssetPathsClass.toString();
  }

  Future<YamlMap?> _createPubspecYampMap(BuildStep buildStep) async {
    final pubspecAssetId = AssetId(buildStep.inputId.package, 'pubspec.yaml');
    final pubspecContent = await buildStep.readAsString(pubspecAssetId);
    return loadYaml(pubspecContent) as YamlMap?;
  }

  Set<String> _getPackagesFromPubspec(YamlMap pubspecYamlMap) {
    if (pubspecYamlMap.containsKey('dependencies')) {
      final dynamic dependenciesMap = pubspecYamlMap['dependencies'];
      if (dependenciesMap is YamlMap) {
        return Set.from(dependenciesMap.keys);
      }
    }

    return {};
  }

  Set<String> _getAssetsListFromPubspec(YamlMap pubspecYamlMap) {
    if (pubspecYamlMap.containsKey('flutter')) {
      final dynamic flutterMap = pubspecYamlMap['flutter'];
      if (flutterMap is YamlMap && flutterMap.containsKey('assets')) {
        final assetsList = flutterMap['assets'] as YamlList;

        // It's valid that set the same asset path multiple times in pubspec.yaml,
        // so the assets can be duplicate, use `Set` here to filter the same asset path.
        return Set.from(assetsList);
      }
    }

    return {};
  }

  /// Get `assets` value from `pubspec.yaml` file.
  Set<Glob> _createAssetsListGlob(YamlMap pubspecYamlMap) {
    final globList = <Glob>{};
    for (final asset in _getAssetsListFromPubspec(pubspecYamlMap)) {
      if (asset.endsWith('/')) {
        globList.add(Glob('$asset*'));
      } else {
        globList.add(Glob(asset));
      }
    }

    return globList;
  }

  Future<List<String>> _findAssetIdPathsFromFlutterAssetsList(
      BuildStep buildStep, YamlMap pubspecYamlMap) async {
    final globList = _createAssetsListGlob(pubspecYamlMap);
    final assetsSet = <AssetId>{};

    for (final glob in globList) {
      final assets = await buildStep.findAssets(glob).toList();
      assetsSet.addAll(assets);
    }

    return assetsSet.map((e) => e.path).toList();
  }

  /// Create [_AssetsScannerOptions] from `assets_scanner_options.yaml` file
  _AssetsScannerOptions _getOptions() {
    final optionsFile = File('assets_scanner_options.yaml');
    if (optionsFile.existsSync()) {
      final optionsContent = optionsFile.readAsStringSync();
      if (optionsContent.isNotEmpty) {
        return _AssetsScannerOptions.fromYamlMap(
            loadYaml(optionsContent) as YamlMap);
      }
    }

    return _AssetsScannerOptions();
  }
}
