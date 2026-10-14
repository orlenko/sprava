#!/bin/sh
# Build build/llm/sprava-llm, the front desk's local model helper (docs/conversation.md 11.2): llama.cpp's llama-server
# at a pinned commit, from a source archive checked by SHA-256, never a Homebrew llama.cpp. Metal is compiled at run time
# (no `metal` compiler, which the Command Line Tools lack) and only system frameworks are linked. Needs cmake
# (brew install cmake). scripts/build-app.sh calls it; a build that matches this script and the Info.plist is kept.
# Also writes build/llm/LICENSES.txt, the notices of llama.cpp (MIT) and of what it links in, for the bundle.
set -eu
cd "$(dirname "$0")/.."

commit=a0e6dc7384edb8f5d927155e1d26c10b4a310e6d
sha256=966f4f0dcbf7029b5b77c220365ba237efe5384a06f554c271faae86a106fbdd
url="https://github.com/ggml-org/llama.cpp/archive/$commit.tar.gz"
plist="$PWD/Resources/sprava-llm-Info.plist"
out="$PWD/build/llm"

# The build is kept while this script and the Info.plist it embeds are unchanged.
key=$(cat scripts/build-llm.sh "$plist" | shasum -a 256 | cut -d' ' -f1)
if [ -x "$out/sprava-llm" ] && [ -f "$out/LICENSES.txt" ] && [ "$(cat "$out/stamp" 2>/dev/null)" = "$key" ]; then
    echo "build-llm: kept $out/sprava-llm (llama.cpp ${commit%"${commit#???????}"})"
    exit 0
fi
command -v cmake >/dev/null 2>&1 || { echo "build-llm: cmake not found: install it (brew install cmake)" >&2; exit 1; }
# CMake splits linker flags on spaces, so the Info.plist's path must have none.
case "$plist" in *[[:space:]]*) echo "build-llm: the checkout's path holds a space; build from a path without one" >&2; exit 1 ;; esac

mkdir -p "$out"
# llama.cpp records its git commit; its archive has none, and the search must not reach this repository's.
export GIT_CEILING_DIRECTORIES="$out"
rm -rf "$out/src" "$out/cmake" "$out/stamp" "$out/source.tar.gz.part"
curl -fsSL --proto '=https' --retry 3 -o "$out/source.tar.gz.part" "$url"
got=$(shasum -a 256 "$out/source.tar.gz.part" | cut -d' ' -f1)
if [ "$got" != "$sha256" ]; then
    rm -f "$out/source.tar.gz.part"
    echo "build-llm: the llama.cpp archive's SHA-256 is $got, not the pinned $sha256; nothing was built" >&2
    exit 1
fi
mkdir "$out/src"
tar -xzf "$out/source.tar.gz.part" -C "$out/src" --strip-components 1
rm -f "$out/source.tar.gz.part"

# Static, Metal source embedded, a CPU baseline every Apple silicon Mac has (not -mcpu=native), and nothing that
# downloads at build or run time: no curl, no OpenSSL, no web UI.
cmake -S "$out/src" -B "$out/cmake" -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
    -DGGML_METAL=ON -DGGML_METAL_EMBED_LIBRARY=ON -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.5-a -DGGML_CCACHE=OFF \
    -DLLAMA_CURL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF \
    -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF \
    "-DCMAKE_EXE_LINKER_FLAGS=-Wl,-sectcreate,__TEXT,__info_plist,$plist"
cmake --build "$out/cmake" --target llama-server -j "$(sysctl -n hw.ncpu)"
built="$out/cmake/bin/llama-server"

# Under the App Sandbox a command-line tool without an embedded Info.plist dies with SIGTRAP at launch.
otool -l "$built" | grep -q 'sectname __info_plist' || { echo "build-llm: llama-server has no embedded Info.plist" >&2; exit 1; }
# Only the system's own libraries: nothing from Homebrew or elsewhere that could move under the app.
foreign=$(otool -L "$built" | tail -n +2 | awk '{ print $1 }' | grep -vE '^(/System/Library/|/usr/lib/)' || true)
if [ -n "$foreign" ]; then
    echo "build-llm: llama-server links libraries outside the system: $foreign" >&2
    exit 1
fi
# The notices CMake gathered for the binary (cmake/license.cmake), as plain text.
sed -n '/^R"=L=(/,/^)=L="/p' "$out/cmake/license.cpp" | sed -e 's/^R"=L=(//' -e 's/^)=L=",*$//' > "$out/LICENSES.txt.part"
grep -q 'License for llama.cpp' "$out/LICENSES.txt.part" || { echo "build-llm: llama.cpp's licence notice was not found" >&2; exit 1; }
mv "$out/LICENSES.txt.part" "$out/LICENSES.txt"
cp "$built" "$out/sprava-llm.part"
mv "$out/sprava-llm.part" "$out/sprava-llm"
echo "$key" > "$out/stamp"
echo "build-llm: built $out/sprava-llm (llama.cpp ${commit%"${commit#???????}"})"
