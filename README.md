# Appcircle Install Tuist and Generate a Project

This step installs [Tuist](https://tuist.io/) and runs `tuist generate` with given options.

## Required Input Variable
- `$AC_TUIST_PATH`: The path to the directory of Tuist project. By default, it is set to the root directory of the cloned repository.

## Optional Input Variable
- `$AC_TUIST_VERSION`: The version of Tuist, you can specify a specific Tuist version. If it is empty, Appcircle installs Tuist 4.214.0.
- `$AC_TUIST_BASE_URL`: Base URL of the Tuist release downloads. Defaults to `https://github.com/tuist/tuist/releases/download`. The step downloads `<base>/<version>/tuist.zip` and verifies it against `<base>/<version>/SHASUMS256.txt`. Set it to an internal mirror to install Tuist without internet access.

The step does not use Homebrew. It skips the download when `tuist version` already reports the requested version, and it sets `TUIST_STATS_OPT_OUT=1`.
