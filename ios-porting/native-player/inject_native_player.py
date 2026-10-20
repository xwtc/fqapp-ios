#!/usr/bin/env python3
"""Adds the native player Swift sources to the generated Xcode project.

`flutter create` regenerates ios/ on every CI run, so the plugin cannot be
committed there. This script is the injection step: it writes the two Swift
files into ios/Runner/ and patches project.pbxproj so the Runner target
compiles them, then wires the plugin into AppDelegate.

Doing it here (rather than as a CocoaPod) keeps the plugin inside Runner.app
itself, which is what a single-binary sideload build wants: no extra framework
to re-sign, and no podspec to keep in sync with upstream.
"""
import pathlib
import re
import sys

PBX = pathlib.Path('ios/Runner.xcodeproj/project.pbxproj')
APP_DELEGATE = pathlib.Path('ios/Runner/AppDelegate.swift')
PLIST = pathlib.Path('ios/Runner/Info.plist')

# Two files, both compiled into the Runner target.
SWIFT_FILES = ['NativePlayerPlugin.swift', 'NativePlayerRegistrar.swift']


def fail(message):
    print('::error::%s' % message)
    sys.exit(1)


def file_uuid(name):
    """Deterministic 24-hex UUID so reruns produce an identical project.

    Xcode only requires uniqueness within the file; a hash of the file name is
    stable across runs, which keeps the diff (and the build cache) quiet.
    """
    import hashlib
    return hashlib.sha256(name.encode()).hexdigest()[:24].upper()


def patch_pbxproj():
    text = PBX.read_text()
    if 'NativePlayerPlugin.swift' in text:
        print('pbxproj already references the plugin sources')
        return

    # 1) PBXFileReference entries, inserted after the first PBXBuildFile section
    #    so the file stays grouped the way Xcode writes it.
    file_refs = []
    build_files = []
    for name in SWIFT_FILES:
        ref = file_uuid('fileref:' + name)
        bf = file_uuid('buildfile:' + name)
        file_refs.append(
            '\t\t%s /* %s */ = {isa = PBXFileReference; '
            'lastKnownFileType = sourcecode.swift; path = %s; sourceTree = "<group>"; };'
            % (ref, name, name)
        )
        build_files.append(
            '\t\t%s /* %s in Sources */ = {isa = PBXBuildFile; fileRef = %s /* %s */; };'
            % (bf, name, ref, name)
        )

    anchor = '/* End PBXFileReference section */'
    if anchor not in text:
        fail('PBXFileReference section not found; project layout changed')
    text = text.replace(anchor, '\n'.join(file_refs) + '\n' + anchor, 1)

    anchor = '/* End PBXBuildFile section */'
    if anchor not in text:
        fail('PBXBuildFile section not found; project layout changed')
    text = text.replace(anchor, '\n'.join(build_files) + '\n' + anchor, 1)

    # 2) Group membership: put the refs in the Runner group so they show up in
    #    Xcode. The group is identified by its `path = Runner;` line.
    group_match = re.search(
        r'(?P<open>[0-9A-F]{24}) /\* Runner \*/ = \{\n'
        r'\t\t\tisa = PBXGroup;\n'
        r'\t\t\tchildren = \(\n'
        r'(?P<children>(?:\t\t\t\t[^\n]*\n)+)'
        r'\t\t\t\);',
        text,
    )
    if not group_match:
        fail('Runner PBXGroup not found; project layout changed')
    children = group_match.group('children')
    if 'AppDelegate.swift' not in children:
        fail('Runner group does not list AppDelegate.swift; refusing to guess')
    additions = ''.join(
        '\t\t\t\t%s /* %s */,\n' % (file_uuid('fileref:' + n), n) for n in SWIFT_FILES
    )
    text = (
        text[: group_match.start('children')]
        + children
        + additions
        + text[group_match.end('children') :]
    )

    # 3) Sources build phase of the Runner target: the one that already
    #    compiles AppDelegate.swift. Matching on that file avoids touching
    #    RunnerTests, which has its own sources phase.
    sources_match = re.search(
        r'(?P<open>[0-9A-F]{24}) /\* Sources \*/ = \{\n'
        r'\t\t\tisa = PBXSourcesBuildPhase;\n'
        r'(?P<rest>(?:[^\n]*\n)*?'
        r'\t\t\tfiles = \(\n'
        r'(?P<files>(?:\t\t\t\t[^\n]*\n)+)'
        r'\t\t\t\);)',
        text,
    )
    patched = False
    for match in re.finditer(
        r'(?P<open>[0-9A-F]{24}) /\* Sources \*/ = \{\n'
        r'\t\t\tisa = PBXSourcesBuildPhase;\n'
        r'(?P<rest>(?:[^\n]*\n)*?'
        r'\t\t\tfiles = \(\n'
        r'(?P<files>(?:\t\t\t\t[^\n]*\n)+)'
        r'\t\t\t\);)',
        text,
    ):
        if 'AppDelegate.swift' not in match.group('files'):
            continue
        files = match.group('files')
        extra = ''.join(
            '\t\t\t\t%s /* %s in Sources */,\n' % (file_uuid('buildfile:' + n), n)
            for n in SWIFT_FILES
        )
        text = (
            text[: match.start('files')]
            + files
            + extra
            + text[match.end('files') :]
        )
        patched = True
        break

    if not patched:
        fail('Runner Sources build phase not found; the plugin would not compile')

    PBX.write_text(text)
    print('pbxproj patched with %d Swift source(s)' % len(SWIFT_FILES))


def patch_app_delegate():
    text = APP_DELEGATE.read_text()
    if 'NativePlayerRegistrar' in text:
        print('AppDelegate already registers the plugin')
        return

    # Flutter 3.44 uses the implicit-engine delegate; older templates call
    # configureFlutterEngine instead. Handle both so this survives a template
    # change without silently doing nothing.
    marker = 'GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)'
    if marker in text:
        text = text.replace(
            marker,
            marker + '\n    NativePlayerRegistrar.register(with: engineBridge.pluginRegistry)',
            1,
        )
    else:
        marker = 'GeneratedPluginRegistrant.register(with: registry)'
        if marker in text:
            text = text.replace(
                marker,
                marker + '\n    NativePlayerRegistrar.register(with: registry)',
                1,
            )
        else:
            fail('no GeneratedPluginRegistrant call in AppDelegate; template changed')

    APP_DELEGATE.write_text(text)
    print('AppDelegate patched')


def patch_plist():
    """Allows cleartext HTTP to the loopback backend.

    The core serves decrypted media from http://127.0.0.1:8080. App Transport
    Security blocks cleartext by default, which would make AVPlayer refuse every
    local URL. NSAllowsLocalNetworking covers exactly the loopback case and is
    narrower than NSAllowsArbitraryLoads: remote https traffic stays enforced.
    """
    import plistlib

    data = plistlib.loads(PLIST.read_bytes())
    ats = data.setdefault('NSAppTransportSecurity', {})
    if ats.get('NSAllowsLocalNetworking') is True:
        print('Info.plist already allows local networking')
        return
    ats['NSAllowsLocalNetworking'] = True
    # Keep the app's own HTTP server reachable from the WebView too.
    ats['NSAllowsArbitraryLoadsInWebContent'] = False
    PLIST.write_bytes(plistlib.dumps(data))
    print('Info.plist: NSAllowsLocalNetworking enabled')


def main():
    if not PBX.exists():
        fail('ios/Runner.xcodeproj/project.pbxproj not found')
    patch_pbxproj()
    patch_app_delegate()
    patch_plist()
    print('native player wired into the Runner target')


main()
