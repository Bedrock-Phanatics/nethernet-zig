param(
    [int]$Jobs = 4,
    [ValidateSet('MbedTLS', 'OpenSSL')]
    [string]$Backend = 'MbedTLS',
    [string]$OpenSslRoot
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root

function Run-Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Program failed with exit code $LASTEXITCODE"
    }
}

function Apply-LibdatachannelPatch([string]$Patch) {
    $savedErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & git -C .deps/libdatachannel apply --reverse --check $Patch 2>$null
    $alreadyApplied = $LASTEXITCODE -eq 0
    $ErrorActionPreference = $savedErrorActionPreference

    if (!$alreadyApplied) {
        Run-Native git @('-C', '.deps/libdatachannel', 'apply', $Patch)
    }
}

if ((& zig version) -ne '0.16.0') {
    throw 'This build requires Zig 0.16.0.'
}

New-Item -ItemType Directory -Force .deps | Out-Null
$cmakeExecutable = '.deps/python/cmake/data/bin/cmake.exe'
$ninjaExecutable = '.deps/python/bin/ninja.exe'
if (!(Test-Path -LiteralPath $cmakeExecutable) -or
    !(Test-Path -LiteralPath $ninjaExecutable)) {
    Run-Native python @(
        '-m',
        'pip',
        'install',
        '--target',
        '.deps/python',
        'cmake==3.31.10',
        'ninja==1.13.0'
    )
}

if (!(Test-Path -LiteralPath .deps/libdatachannel/.git)) {
    Run-Native git @(
        'clone',
        '--branch', 'v0.24.5',
        '--depth', '1',
        '--recurse-submodules',
        '--shallow-submodules',
        'https://github.com/paullouisageneau/libdatachannel.git',
        '.deps/libdatachannel'
    )
}

if ($Backend -eq 'MbedTLS' -and !(Test-Path -LiteralPath .deps/mbedtls/.git)) {
    Run-Native git @(
        'clone',
        '--branch', 'mbedtls-3.6.7',
        '--depth', '1',
        '--recurse-submodules',
        '--shallow-submodules',
        'https://github.com/Mbed-TLS/mbedtls.git',
        '.deps/mbedtls'
    )
}

$libdatachannelCommit = & git -C .deps/libdatachannel rev-parse HEAD
if ($libdatachannelCommit -ne '443f6934d9007eb7076ab7825ba330f355fcbead') {
    throw 'Unexpected libdatachannel checkout.'
}

if ($Backend -eq 'MbedTLS') {
    $mbedTag = & git -C .deps/mbedtls describe --tags --exact-match
    $mbedCommit = & git -C .deps/mbedtls rev-parse HEAD
    if ($mbedTag -notin @('mbedtls-3.6.7', 'v3.6.7') -or
        $mbedCommit -ne '068ff080b369adfac81509f9b57b2afabaf82dc5') {
        throw 'Unexpected Mbed TLS checkout.'
    }

    Run-Native python @(
        '.deps/mbedtls/scripts/config.py',
        '-f',
        '.deps/mbedtls/include/mbedtls/mbedtls_config.h',
        'set',
        'MBEDTLS_SSL_DTLS_SRTP'
    )
}

Apply-LibdatachannelPatch (Join-Path $root 'tools/libdatachannel-bounds.patch')
if ($Backend -eq 'MbedTLS') {
    Apply-LibdatachannelPatch (Join-Path $root 'tools/libdatachannel-mbedtls-link-order.patch')
}

foreach ($tool in @{
    'cc' = 'cc'
    'cxx' = 'c++'
    'ar' = 'ar'
    'ranlib' = 'ranlib'
}.GetEnumerator()) {
    Set-Content -LiteralPath ".deps/zig-$($tool.Key).cmd" `
        -Value "@echo off`nzig $($tool.Value) %*"
}

$prefix = $root.Replace('\', '/')
$cmake = Join-Path $root $cmakeExecutable
if ($Backend -eq 'OpenSSL') {
    if (!$OpenSslRoot) {
        throw 'OpenSSL builds require -OpenSslRoot pointing to an OpenSSL installation.'
    }
    $OpenSslRoot = (Resolve-Path -LiteralPath $OpenSslRoot).Path.Replace('\', '/')
    if (!(Test-Path -LiteralPath "$OpenSslRoot/include/openssl/ssl.h")) {
        throw "OpenSSL headers not found in $OpenSslRoot"
    }
    $nativePrefix = "$prefix/.deps/native-openssl"
    $rtcBuild = '.deps/rtc-openssl-build'
    $tlsOptions = @('-DUSE_MBEDTLS=OFF', "-DOPENSSL_ROOT_DIR=$OpenSslRoot")
    $tlsPrefix = $OpenSslRoot
} else {
    $nativePrefix = "$prefix/.deps/native"
    $rtcBuild = '.deps/rtc-build'
    $tlsOptions = @('-DUSE_MBEDTLS=ON')
    $tlsPrefix = $nativePrefix
}
$common = @(
    '-G', 'Ninja',
    "-DCMAKE_MAKE_PROGRAM=$prefix/.deps/python/bin/ninja.exe",
    "-DCMAKE_C_COMPILER=$prefix/.deps/zig-cc.cmd",
    "-DCMAKE_AR=$prefix/.deps/zig-ar.cmd",
    "-DCMAKE_RANLIB=$prefix/.deps/zig-ranlib.cmd",
    '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_INSTALL_PREFIX=$nativePrefix"
)

if ($Backend -eq 'MbedTLS') {
    $mbedtlsConfigure = @(
        '-S', '.deps/mbedtls',
        '-B', '.deps/mbedtls-build',
        '-DENABLE_TESTING=OFF',
        '-DENABLE_PROGRAMS=OFF'
    ) + $common
    Run-Native $cmake $mbedtlsConfigure
    Run-Native $cmake @(
        '--build', '.deps/mbedtls-build',
        '-j', "$Jobs",
        '--target', 'install'
    )
}

$libdatachannelConfigure = @(
    '-S', '.deps/libdatachannel',
    '-B', $rtcBuild,
    "-DCMAKE_CXX_COMPILER=$prefix/.deps/zig-cxx.cmd",
    "-DCMAKE_PREFIX_PATH=$tlsPrefix",
    '-DNO_TESTS=ON',
    '-DNO_EXAMPLES=ON',
    '-DNO_MEDIA=ON',
    '-DNO_WEBSOCKET=ON',
    '-DBUILD_SHARED_LIBS=ON'
) + $tlsOptions + $common
Run-Native $cmake $libdatachannelConfigure
Run-Native $cmake @(
    '--build', $rtcBuild,
    '-j', "$Jobs",
    '--target', 'install'
)

if ($Backend -eq 'OpenSSL') {
    foreach ($pattern in @('libcrypto*.dll', 'libssl*.dll')) {
        $dlls = @(Get-ChildItem -Path "$OpenSslRoot/bin/$pattern" -ErrorAction SilentlyContinue)
        if ($dlls.Count -ne 1) {
            throw "Expected one $pattern runtime DLL in $OpenSslRoot/bin"
        }
        Copy-Item -LiteralPath $dlls[0].FullName -Destination "$nativePrefix/bin"
    }
}
