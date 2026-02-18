# Changelog

All notable changes to the Impact Creator LWC project will be documented in this file.

**JIRA Ticket**: [MSBDC-77](https://attainpartners.atlassian.net/browse/MSBDC-77)

## [Unreleased]

## [2026-02-18] - Initial Development Session

### Added
- Quick Action metadata (`Case.New_Impact`) for launching Impact Creator as modal
- Auto-creation of missing Standard Pricebook entries for Products
- Responsive CSS Grid layout for Capital Sources configuration
- Comprehensive README.md with installation and usage documentation
- Test coverage for auto PricebookEntry creation

### Changed
- Updated LWC meta.xml to support both `lightning__RecordAction` and `lightning__RecordPage` targets
- Shortened field labels in Capital Sources section for better modal fit (Type, Partner, Qty)
- Improved responsive breakpoints for modal display (900px, 600px)

### Fixed
- "No active Pricebook Entry found" error when selecting Capital Sources without existing PricebookEntries

### Deployed
- **Target Org**: mi-sbdc-sandbox (mjdavis@attainpartners.com.sbdc.fullsb)
- **Components**: ImpactCreatorController, ImpactCreatorControllerTest, impactCreator LWC

### Repository
- Pushed to GitHub: https://github.com/mauricedavis/ImpactCreatorLWC

### Awaiting
- Client review and feedback on Quick Action modal functionality
- Client review of responsive UI in Capital Sources section
