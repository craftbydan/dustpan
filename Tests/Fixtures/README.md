# Fixtures

Fake home-folder trees used by scanner and Cleaner tests. They are generated at test time in a
temp directory by `Tests/DustpanTests/Fixtures/FixtureHome.swift` (files of known size and age,
symlinks, protected places). Tests inject the fake home into the scanner; they never touch the
real home folder.
