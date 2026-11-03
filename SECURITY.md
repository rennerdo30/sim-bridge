# Security reporting

Do not post recovery codes, root keys, device tokens, relay owner keys, phone numbers, message bodies, signing material, or live databases in issues or logs.

For confidential vulnerabilities, email support@renner.dev, or use GitHub private vulnerability reporting if it is available for this repository. Include only a minimal synthetic reproduction; do not include live credentials or message content.

Include affected commit/version, platform, a minimal reproduction using synthetic data, and the security impact. Tests must use isolated relay ports and disposable credentials; do not test against someone else’s gateway or live paired state.

No release currently has a guaranteed security-support window. Maintainers review reports against the current source and record fixes in release notes. Passing tests is not a complete security audit. See the documentation for encryption boundaries and metadata visibility.
