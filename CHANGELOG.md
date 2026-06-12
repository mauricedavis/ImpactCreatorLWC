# Changelog

All notable changes to the Impact Creator LWC project will be documented in this file.

**JIRA Ticket**: [MSBDC-77](https://attainpartners.atlassian.net/browse/MSBDC-77)

## [Unreleased]

## [2026-03-11] - MSBDC-93 Phase 1: Target_Impact__c Stamping

### Context
Part of the Target rollup re-architecture (MSBDC-93 Phase 1). The existing
`Target_Rollups` scheduled flow used fragile name-based matching
(`Center_Region__c` text string) to associate Impact Team Members with
Center/Region targets. This change begins the migration to ID-based matching
by stamping `Target_Impact__c` on `OpportunityTeamMember` at Impact creation time.

### Changed
- **ImpactCreatorController.cls** — Added `stampTargetImpact()` private method.
  After inserting `OpportunityTeamMember` records, resolves the matching
  `Current` Consultant `Target__c` for each team member's `UserId` +
  attribution year and sets `Target_Impact__c` accordingly.
  - Applies to both the explicit team members path and the auto-owner fallback path
  - Gracefully skips team members with no matching Target (no exception thrown)
  - `@TestVisible` annotation exposes method for direct unit testing

### Added
- **ImpactCreatorControllerTest.cls** — Five new test methods covering the stamping logic:
  - `testCreateImpact_StampsTargetImpact` — happy path; verifies stamp when matching Target exists
  - `testCreateImpact_NoTargetGraceful` — verifies no error when no matching Target (future year)
  - `testCreateImpact_AutoOwner_StampsTarget` — verifies stamp on auto-owner fallback path
  - `testStampTargetImpact_EmptyList` — unit tests guard clause for empty/null input directly
  - `testCreateImpact_MultipleTeamMembers_PartialStamp` — partial stamp when only some members have Targets
  - `@TestSetup` updated to insert a Current Consultant Target for the running user

### Not Changed
- LWC (impactCreator.html / .js / .css) — no changes
- Quick Action metadata — no changes
- All original test methods preserved and still passing

### Deployment
- **Target Org**: mi-sbdc-sandbox → Production (post-sandbox validation)
- **Deploy Command**:
  ```
  sf project deploy start \
    --source-dir force-app/main/default/classes/ImpactCreatorController.cls \
    --source-dir force-app/main/default/classes/ImpactCreatorControllerTest.cls \
    --target-org mi-sbdc-sandbox \
    --test-level RunSpecifiedTests \
    --tests ImpactCreatorControllerTest
  ```

### Next Steps (MSBDC-93 Phase 1 continued)
- Step 2: Run backfill SOQL validation to confirm UserId → Target__c join resolves
  cleanly across existing 4,830 OpportunityTeamMember records
- Step 3: Data Loader backfill of Target_Impact__c on historical records
- Step 4: Rebuild Target_Rollups flow Center/Region path using Target_Impact__c ID lookup

---

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
