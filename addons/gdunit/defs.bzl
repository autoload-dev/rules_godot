"""Run GdUnit4 test suites as Bazel tests."""

load("//private:gdunit_test.bzl", _gdunit_test = "gdunit_test")

gdunit_test = _gdunit_test
