param([int]$Jobs = 4)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location -LiteralPath $root
function Run-Native([string]$Program, [string[]]$Arguments) {
    & $Program @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Program failed with exit code $LASTEXITCODE" }
}
if ((& zig version) -ne '0.16.0') { throw 'This build requires Zig 0.16.0.' }
New-Item -ItemType Directory -Force .deps | Out-Null
if (!(Test-Path -LiteralPath .deps/python/cmake/data/bin/cmake.exe) -or !(Test-Path -LiteralPath .deps/python/bin/ninja.exe)) {
    Run-Native python @('-m','pip','install','--target','.deps/python','cmake==3.31.10','ninja==1.13.0')
}
if (!(Test-Path -LiteralPath .deps/libdatachannel/.git)) {
    Run-Native git @('clone','--branch','v0.24.5','--depth','1','--recurse-submodules','--shallow-submodules','https://github.com/paullouisageneau/libdatachannel.git','.deps/libdatachannel')
}
if (!(Test-Path -LiteralPath .deps/mbedtls/.git)) {
    Run-Native git @('clone','--branch','mbedtls-3.6.7','--depth','1','--recurse-submodules','--shallow-submodules','https://github.com/Mbed-TLS/mbedtls.git','.deps/mbedtls')
}
if ((& git -C .deps/libdatachannel rev-parse HEAD) -ne '443f6934d9007eb7076ab7825ba330f355fcbead') { throw 'Unexpected libdatachannel checkout.' }
$mbedTag = & git -C .deps/mbedtls describe --tags --exact-match
if ($mbedTag -notin @('mbedtls-3.6.7','v3.6.7') -or (& git -C .deps/mbedtls rev-parse HEAD) -ne '068ff080b369adfac81509f9b57b2afabaf82dc5') { throw 'Unexpected Mbed TLS checkout.' }
Run-Native python @('.deps/mbedtls/scripts/config.py','-f','.deps/mbedtls/include/mbedtls/mbedtls_config.h','set','MBEDTLS_SSL_DTLS_SRTP')
$patch = Join-Path $root 'tools/libdatachannel-bounds.patch'
$savedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& git -C .deps/libdatachannel apply --reverse --check $patch 2>$null
$patchAlreadyApplied = $LASTEXITCODE -eq 0
$ErrorActionPreference = $savedErrorActionPreference
if (!$patchAlreadyApplied) { Run-Native git @('-C','.deps/libdatachannel','apply',$patch) }
foreach ($tool in @{'cc'='cc'; 'cxx'='c++'; 'ar'='ar'; 'ranlib'='ranlib'}.GetEnumerator()) {
    Set-Content -LiteralPath ".deps/zig-$($tool.Key).cmd" -Value "@echo off`nzig $($tool.Value) %*"
}
$prefix = $root.Replace('\','/')
$cmake = Join-Path $root '.deps/python/cmake/data/bin/cmake.exe'
$common = @('-G','Ninja',"-DCMAKE_MAKE_PROGRAM=$prefix/.deps/python/bin/ninja.exe", "-DCMAKE_C_COMPILER=$prefix/.deps/zig-cc.cmd", "-DCMAKE_AR=$prefix/.deps/zig-ar.cmd", "-DCMAKE_RANLIB=$prefix/.deps/zig-ranlib.cmd", '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_INSTALL_PREFIX=$prefix/.deps/native")
Run-Native $cmake (@('-S','.deps/mbedtls','-B','.deps/mbedtls-build','-DENABLE_TESTING=OFF','-DENABLE_PROGRAMS=OFF') + $common)
Run-Native $cmake @('--build','.deps/mbedtls-build','-j',"$Jobs",'--target','install')
Run-Native $cmake (@('-S','.deps/libdatachannel','-B','.deps/rtc-build',"-DCMAKE_CXX_COMPILER=$prefix/.deps/zig-cxx.cmd", "-DCMAKE_PREFIX_PATH=$prefix/.deps/native", '-DNO_TESTS=ON','-DNO_EXAMPLES=ON','-DNO_MEDIA=ON','-DNO_WEBSOCKET=ON','-DUSE_MBEDTLS=ON','-DBUILD_SHARED_LIBS=ON') + $common)
Run-Native $cmake @('--build','.deps/rtc-build','-j',"$Jobs",'--target','install')
