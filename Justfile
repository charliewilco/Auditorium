set shell := ["zsh", "-cu"]

swift_format_files := "Auditorium Tests"
xcode_destination := "platform=macOS,arch=arm64"

default:
	@just --list

build:
	swift build
	cargo build --all-targets

test:
	swift test
	cargo test --all-targets

format:
	swift-format format --configuration .swift-format --recursive --in-place {{swift_format_files}}
	cargo fmt --all

cli *args:
	cargo run -p symphony -- {{args}}

desktop:
	xcodebuild build -workspace Auditorium.xcworkspace -scheme Auditorium -configuration Debug -destination '{{xcode_destination}}' CODE_SIGNING_ALLOWED=NO
