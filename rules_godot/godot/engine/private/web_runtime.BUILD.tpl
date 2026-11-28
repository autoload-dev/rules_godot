prebuilt_runtime(
    name = {NAME},
    cpu = "wasm32",
    binary = {BINARY},
    bundled_packages = [{BUNDLED_PACKAGES}],
    data = glob([{FILES}]),
    digest = {DIGEST},
    emscripten_version = {EMSCRIPTEN_VERSION},
    platform = "web",
    variant = {VARIANT},
    version = {VERSION},
)
