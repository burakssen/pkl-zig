#!/bin/sh
set -eu

GENERATOR=$1
OUT=$2

check_fails() {
  input=$1
  expected=$2
  if output=$(pkl run "$GENERATOR" --output-path "$OUT" "$input" 2>&1); then
    printf 'expected %s to fail, but it succeeded\n' "$input" >&2
    exit 1
  fi
  case "$output" in
    *"$expected"*) ;;
    *)
      printf 'expected %s failure to contain: %s\n' "$input" "$expected" >&2
      printf '%s\n' "$output" >&2
      exit 1
      ;;
  esac
}

check_fails codegen/snippet-tests/input/ConflictingNames.err.pkl 'Conflict: multiple Pkl declarations compute to Zig name `ClassOne`.'
check_fails codegen/snippet-tests/input/ConflictingNames2.err.pkl 'Conflict: multiple Pkl declarations compute to Zig name `ConflictingNames2`.'
check_fails codegen/snippet-tests/input/IllegalOverride.err.pkl 'Illegal override: property `prop`'
