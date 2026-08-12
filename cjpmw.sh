#!/usr/bin/env bash
eval "$(cjvs env bash)"
eval "$(cjvs stdx-env bash)"
cjpm "$@"
