# Contributing to PopGuy

Thanks for your interest — contributions are welcome!

## How to contribute

- **Found a bug or have an idea?** Open an issue to discuss it first.
- **Sending code?**
  1. Build from source and make sure `xcodebuild test -project macos/PopGuy.xcodeproj -scheme PopGuy -destination 'platform=macOS'` passes.
  2. Match the existing style — the project is Swift 6 with strict concurrency.
  3. Keep pull requests focused, and describe what changed and why.
- **Changing the Windows port (`windows/`)?**
  1. Run its tests: `dotnet test windows/tests/PopGuy.Tests/PopGuy.Tests.csproj` (.NET 10 SDK; works on macOS
     and Windows).
  2. The app itself (WinUI 3) is built by GitHub Actions (`.github/workflows/windows.yml`) on every pull request that
     touches `windows/`; check that the run is green. See [windows/README.md](windows/README.md).
  3. UI text is English only; tooltips go through the app's `HoverTooltip`, never the default WinUI tooltip.

## License

PopGuy is open source under the **GNU Affero General Public License v3.0**. By
submitting a contribution, you agree that it is licensed under the same terms. You
confirm that the contribution is your own original work, or that you are authorized to
submit it.

No Contributor License Agreement is required.
