/**
 * @description Test class for ImpactCreatorController
 * @author      Auto-generated for Michigan SBDC
 * @date        2026-02-12
 * @modified    2026-03-11 - MJD (MSBDC-93 Phase 1)
 *              Added test coverage for Target_Impact__c stamping:
 *              - testCreateImpact_StampsTargetImpact: verifies stamp when a
 *                matching Current Consultant Target exists for the year.
 *              - testCreateImpact_NoTargetGraceful: verifies no error when no
 *                matching Target exists (graceful skip).
 *              - testCreateImpact_AutoOwner_StampsTarget: verifies stamp
 *                applies on the auto-owner fallback path.
 *              - testStampTargetImpact_EmptyList: unit-tests the private method
 *                directly via @TestVisible for the empty-input guard.
 */
@isTest
private class ImpactCreatorControllerTest {

    // ── Test Setup ─────────────────────────────────────────────────────

    @TestSetup
    static void setup() {
        // Account
        Account acc = new Account(
            Name           = 'Test Account',
            Start_Date__c  = Date.today().addMonths(-6),
            In_Business__c = true
        );
        insert acc;

        // Case (owner defaults to running user)
        Case c = new Case(
            Subject   = 'Test Case',
            AccountId = acc.Id
        );
        insert c;

        // Products — intentionally no Partner_Type__c so OLI validation rules
        // (Partner_Type_Must_Match_Lender / _Capital_Provider) do not fire.
        // Those rules require a partner Account when Partner_Type__c is set,
        // which is impractical to satisfy in a unit test context.
        Product2 prod1 = new Product2(Name = 'SBA 7(a) Loan',  IsActive = true);
        Product2 prod2 = new Product2(Name = 'SBA 504 Loan',   IsActive = true);
        insert new List<Product2>{ prod1, prod2 };

        // Standard Pricebook Entries
        Id stdPbId = Test.getStandardPricebookId();
        insert new List<PricebookEntry>{
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod1.Id, UnitPrice = 0, IsActive = true),
            new PricebookEntry(Pricebook2Id = stdPbId, Product2Id = prod2.Id, UnitPrice = 0, IsActive = true)
        };

        // Consultant Target for the running user, current year
        // This Target is used by the stamping tests to confirm Target_Impact__c is set.
        String thisYear = String.valueOf(Date.today().year());
        Target__c consultantTarget = new Target__c(
            Name                   = 'Test Consultant Target ' + thisYear,
            Consultant_Name__c     = UserInfo.getUserId(),
            Target_Start_Date__c   = Date.newInstance(Date.today().year(), 1, 1),
            Status__c              = 'Current'
        );
        insert consultantTarget;
    }

    // ── Existing Tests (unchanged) ─────────────────────────────────────

    @isTest
    static void testGetInitData() {
        Case c = [SELECT Id FROM Case LIMIT 1];

        Test.startTest();
        ImpactCreatorController.InitData data = ImpactCreatorController.getInitData(c.Id);
        Test.stopTest();

        System.assertNotEquals(null, data.caseRecord, 'Case should be returned');
        System.assertNotEquals(null, data.accountName, 'Account name should be populated');
        System.assert(data.capitalSources.size() >= 2, 'Should have at least 2 capital sources');
        System.assert(!data.stageOptions.isEmpty(), 'Stage options should not be empty');
        System.assert(!data.salesSourceOptions.isEmpty(), 'Sales Source options should not be empty');
        System.assert(!data.teamRoleOptions.isEmpty(), 'Team Role options should not be empty');
    }

    @isTest
    static void testCreateImpactFull() {
        Case c        = [SELECT Id, OwnerId FROM Case LIMIT 1];
        List<Product2> prods = [SELECT Id, Name FROM Product2 ORDER BY Name];

        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        payload.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>();
        for (Product2 p : prods) {
            ImpactCreatorController.CapitalSourceLine csl = new ImpactCreatorController.CapitalSourceLine();
            csl.productId         = p.Id;
            csl.productName       = p.Name;
            csl.amount            = 100000;
            csl.serviceDate       = Date.today();
            csl.quantity          = 1;
            payload.capitalSourceLines.add(csl);
        }
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>();
        payload.teamMembers.add(buildTeamMember(c.OwnerId, 'Lead Consultant', 200000, 5, 10, 50000));

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        System.assertEquals(2, result.oliCount, 'Should have 2 OLIs');
        System.assertEquals(1, result.teamMemberCount, 'Should have 1 team member');

        Opportunity opp = [SELECT Id, Name, Jobs_Created__c FROM Opportunity WHERE Id = :result.opportunityId];
        System.assertEquals('Test Impact', opp.Name);
        System.assertEquals(5, opp.Jobs_Created__c);
    }

    @isTest
    static void testSearchUsers() {
        Test.startTest();
        List<ImpactCreatorController.UserOption> users = ImpactCreatorController.searchUsers('a');
        Test.stopTest();
        System.assert(users != null, 'Should return a list');
    }

    /**
     * Verifies that createImpact() correctly inserts a single Capital Source OLI
     * when the product has a pre-existing Standard Pricebook Entry.
     */
    @isTest
    static void testCreateImpactSingleCapitalSource() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];
        Product2 prod = [SELECT Id, Name FROM Product2 WHERE Name = 'SBA 7(a) Loan' LIMIT 1];

        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        ImpactCreatorController.CapitalSourceLine csl = new ImpactCreatorController.CapitalSourceLine();
        csl.productId   = prod.Id;
        csl.productName = prod.Name;
        csl.amount      = 50000;
        csl.serviceDate = Date.today();
        csl.quantity    = 1;
        payload.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>{ csl };
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>{
            buildTeamMember(c.OwnerId, 'Lead Consultant', 50000, 2, 3, 25000)
        };

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        System.assertEquals(1, result.oliCount, 'Should have 1 OLI');

        List<OpportunityLineItem> olis = [
            SELECT Id, UnitPrice FROM OpportunityLineItem
            WHERE OpportunityId = :result.opportunityId
        ];
        System.assertEquals(1, olis.size(), 'One OLI should exist');
        System.assertEquals(50000, olis[0].UnitPrice, 'OLI amount should match');
    }

    /**
     * Verifies that a product with no Standard PricebookEntry causes the controller
     * to throw a meaningful AuraHandledException rather than a generic error.
     */
    @isTest
    static void testCreateImpact_MissingPricebookEntry_ThrowsError() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        Product2 noPbeProd = new Product2(Name = 'No PBE Product', IsActive = true);
        insert noPbeProd;

        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        ImpactCreatorController.CapitalSourceLine csl = new ImpactCreatorController.CapitalSourceLine();
        csl.productId   = noPbeProd.Id;
        csl.productName = noPbeProd.Name;
        csl.amount      = 10000;
        csl.quantity    = 1;
        payload.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>{ csl };
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>{
            buildTeamMember(c.OwnerId, 'Lead Consultant', 0, 0, 0, 0)
        };

        // Note: AuraHandledException.getMessage() always returns 'Script-thrown exception'
        // at the Salesforce platform level regardless of the message set on the exception.
        // We assert that the exception type was thrown — that is sufficient verification
        // that the controller's guard clause fired correctly.
        Boolean exceptionThrown = false;
        Test.startTest();
        try {
            ImpactCreatorController.createImpact(JSON.serialize(payload));
            System.assert(false, 'Should have thrown AuraHandledException for missing PBE');
        } catch (AuraHandledException e) {
            exceptionThrown = true;
        }
        Test.stopTest();
        System.assert(exceptionThrown, 'AuraHandledException should have been thrown for a product with no PricebookEntry');
    }

    // ── New Tests: Target_Impact__c Stamping ───────────────────────────

    /**
     * Happy path: a Current Consultant Target exists for the running user
     * and the Impact's attribution year. Verifies Target_Impact__c is stamped
     * on the inserted OpportunityTeamMember after createImpact() completes.
     */
    @isTest
    static void testCreateImpact_StampsTargetImpact() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        // Confirm the setup Target exists for this year
        String thisYear = String.valueOf(Date.today().year());
        List<Target__c> targets = [
            SELECT Id FROM Target__c
            WHERE Consultant_Name__c = :c.OwnerId
              AND Target_Year__c = :thisYear
              AND Status__c = 'Current'
        ];
        System.assertEquals(1, targets.size(), 'Setup Target should exist for running user + year');
        Id expectedTargetId = targets[0].Id;

        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>{
            buildTeamMember(c.OwnerId, 'Lead Consultant', 100000, 2, 0, 0)
        };

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        // Verify the stamp was applied
        OpportunityTeamMember tm = [
            SELECT Id, Target_Impact__c
            FROM OpportunityTeamMember
            WHERE OpportunityId = :result.opportunityId
            LIMIT 1
        ];
        System.assertEquals(
            expectedTargetId,
            tm.Target_Impact__c,
            'Target_Impact__c should be stamped with the matching Consultant Target Id'
        );
    }

    /**
     * Graceful skip: no matching Target exists for the team member's user + year.
     * Verifies createImpact() completes without error and Target_Impact__c = null.
     */
    @isTest
    static void testCreateImpact_NoTargetGraceful() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        // Use an attribution date from a year with no Target records
        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        payload.attributionDate = Date.newInstance(2099, 6, 1); // Future year — no Target
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>{
            buildTeamMember(c.OwnerId, 'Lead Consultant', 0, 0, 0, 0)
        };

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        System.assertNotEquals(null, result.opportunityId, 'Impact should be created even without a matching Target');

        OpportunityTeamMember tm = [
            SELECT Id, Target_Impact__c
            FROM OpportunityTeamMember
            WHERE OpportunityId = :result.opportunityId
            LIMIT 1
        ];
        System.assertEquals(
            null,
            tm.Target_Impact__c,
            'Target_Impact__c should remain null when no matching Target found — no error should be thrown'
        );
    }

    /**
     * Auto-owner path: when no team members are passed, the Case Owner is
     * auto-assigned as Lead Consultant. Verifies stamping also occurs on this path.
     */
    @isTest
    static void testCreateImpact_AutoOwner_StampsTarget() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        String thisYear = String.valueOf(Date.today().year());
        List<Target__c> targets = [
            SELECT Id FROM Target__c
            WHERE Consultant_Name__c = :c.OwnerId
              AND Target_Year__c = :thisYear
              AND Status__c = 'Current'
        ];
        System.assertEquals(1, targets.size(), 'Setup Target should exist for running user + year');
        Id expectedTargetId = targets[0].Id;

        // No teamMembers on payload — triggers auto-owner fallback
        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        payload.teamMembers = null;

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        System.assertEquals(1, result.teamMemberCount, 'Auto-owner should create 1 team member');

        OpportunityTeamMember tm = [
            SELECT Id, Target_Impact__c, TeamMemberRole
            FROM OpportunityTeamMember
            WHERE OpportunityId = :result.opportunityId
            LIMIT 1
        ];
        System.assertEquals('Lead Consultant', tm.TeamMemberRole, 'Auto-owner should be Lead Consultant');
        System.assertEquals(
            expectedTargetId,
            tm.Target_Impact__c,
            'Target_Impact__c should be stamped on the auto-owner team member'
        );
    }

    /**
     * Unit test for the @TestVisible stampTargetImpact() method directly.
     * Passes an empty list — confirms the guard clause exits cleanly.
     */
    @isTest
    static void testStampTargetImpact_EmptyList() {
        Test.startTest();
        // Should complete with no exception
        ImpactCreatorController.stampTargetImpact(
            new List<OpportunityTeamMember>(),
            String.valueOf(Date.today().year())
        );
        ImpactCreatorController.stampTargetImpact(null, '2026');
        Test.stopTest();
        System.assert(true, 'Empty/null list should exit gracefully without error');
    }

    /**
     * Multiple team members on the same Impact — each should get their own
     * Target_Impact__c stamped if a matching Target exists for their UserId.
     * One member has a Target, one does not — verifies partial stamping works.
     */
    @isTest
    static void testCreateImpact_MultipleTeamMembers_PartialStamp() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        // Running user has a Target (from setup). Create a second active user
        // with no Target to confirm partial stamping.
        User noTargetUser = [
            SELECT Id FROM User
            WHERE IsActive = true
              AND UserType = 'Standard'
              AND Id != :c.OwnerId
            LIMIT 1
        ];

        String thisYear = String.valueOf(Date.today().year());
        List<Target__c> targets = [
            SELECT Id FROM Target__c
            WHERE Consultant_Name__c = :c.OwnerId
              AND Target_Year__c = :thisYear
              AND Status__c = 'Current'
        ];
        Id expectedTargetId = targets.isEmpty() ? null : targets[0].Id;

        ImpactCreatorController.CreatePayload payload = buildBasePayload(c.Id);
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>{
            buildTeamMember(c.OwnerId,       'Lead Consultant', 100000, 2, 0, 0),
            buildTeamMember(noTargetUser.Id, 'Consultant',      0, 0, 0, 0)
        };

        Test.startTest();
        ImpactCreatorController.CreateResult result =
            ImpactCreatorController.createImpact(JSON.serialize(payload));
        Test.stopTest();

        System.assertEquals(2, result.teamMemberCount, 'Should have 2 team members');

        List<OpportunityTeamMember> tms = [
            SELECT Id, UserId, Target_Impact__c
            FROM OpportunityTeamMember
            WHERE OpportunityId = :result.opportunityId
            ORDER BY CreatedDate ASC
        ];
        System.assertEquals(2, tms.size(), 'Two team members should be created');

        for (OpportunityTeamMember tm : tms) {
            if (tm.UserId == c.OwnerId) {
                System.assertEquals(
                    expectedTargetId,
                    tm.Target_Impact__c,
                    'Owner team member should have Target_Impact__c stamped'
                );
            } else {
                System.assertEquals(
                    null,
                    tm.Target_Impact__c,
                    'Second team member with no Target should have null Target_Impact__c'
                );
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────

    private static ImpactCreatorController.CreatePayload buildBasePayload(String caseId) {
        ImpactCreatorController.CreatePayload p = new ImpactCreatorController.CreatePayload();
        p.caseId          = caseId;
        p.impactName      = 'Test Impact';
        p.attributionDate = Date.today();
        p.stageName       = 'Impact Created';
        p.salesIncrease   = 50000;
        p.salesSource     = 'New Business';
        p.jobsCreated     = 5;
        p.jobsRetained    = 10;
        p.newBusiness     = true;
        p.boughtBusiness  = false;
        p.soldBusiness    = false;
        p.businessStartDate = null;
        p.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>();
        p.teamMembers     = new List<ImpactCreatorController.TeamMemberLine>();
        return p;
    }

    private static ImpactCreatorController.TeamMemberLine buildTeamMember(
        String userId, String role,
        Decimal capital, Integer jobsCreated, Integer jobsRetained, Decimal sales
    ) {
        ImpactCreatorController.TeamMemberLine tm = new ImpactCreatorController.TeamMemberLine();
        tm.userId          = userId;
        tm.role            = role;
        tm.capitalFormation = capital;
        tm.jobsCreated     = jobsCreated;
        tm.jobsRetained    = jobsRetained;
        tm.salesIncrease   = sales;
        return tm;
    }
}
