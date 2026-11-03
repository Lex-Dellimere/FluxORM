# Compiler repros found while building reach

Each file is minimal and self-contained. Run from this directory with the head
compiler:

```
M=/home/nox/Projects/mettle/raize/mettle-build/bin/mettle
$M --build ice_call_indirect.mettle -o /tmp/x            # ok
$M --release --build ice_call_indirect.mettle -o /tmp/x  # ICE
```

## ice_call_indirect.mettle

```
Code generation error: Direct object backend cannot compile function 'main'
(call_indirect_unsupported)
Mettle internal compiler error: Code generation failed
Phase: codegen
```

Trigger: a **local** struct whose function-pointer field is `0`, passed to a
function that calls through that field. The optimizer folds the known-null
pointer; the direct object backend then refuses the indirect call. Debug is
unaffected.

Workaround used in reach: build the value behind
`@noinline export fn rc_adapter_empty() -> RcAdapter`
(`ice_call_indirect_workaround.mettle` proves it). `@noinline` must sit on the
same line as `fn`; a newline between them is a parse error whose diagnostic
points at the next file's line.

## Second finding (no repro file; it is a compile error, not a crash)

A module-scope `var` referenced from inside a `comptime for` body **in an
imported module** fails with `Undefined variable '<NAME>'` at expansion time.
Passing the destination as a function parameter works. See
`tests/models.mettle::user_fields` for the shape that compiles.
