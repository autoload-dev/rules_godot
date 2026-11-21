# Fixtures of godot/private/tests/adapter

Each section names a fixture and what it reproduces for the tests of this package.

## fake_adapter

The smallest test adapter: a main script that selects its cases with rules_godot's case
selection and decides the test by its exit code, as a test framework's adapter, such as
autoload_gdunit's, does.

## cases

A project with the fake adapter's cases: text files named `*_case.txt` that hold `pass`,
`fail` or `error`, and a file beside them that is no case.
