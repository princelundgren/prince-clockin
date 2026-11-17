# PrinceClockIn

A macOS menu bar app that shows how long each command-line cloud login has left, warns before one
expires, and logs in to the ones you pick, one after another, when you click.

It tracks AWS IAM Identity Center sessions (`aws sso login`), Databricks CLI profiles
(`databricks auth login`) and any other login as a timer you start by hand. It never logs in on its
own, and it collects nothing: no telemetry, analytics or crash reporting.

**Status:** in development; there is no release yet. The design is in
[`docs/superpowers/specs/2026-11-17-princeclockin-design.md`](docs/superpowers/specs/2026-11-17-princeclockin-design.md).

## Support

Report a bug or ask a question in [GitHub issues](https://github.com/princelundgren/prince-clockin/issues).

## License

[MIT](LICENSE)
