#!/bin/sh
set -eu
git config core.hooksPath .githooks
printf '%s\n' 'Configured Git to use .githooks for this checkout.'
