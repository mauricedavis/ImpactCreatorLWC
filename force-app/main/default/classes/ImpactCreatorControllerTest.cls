/**
 * @description Test class for ImpactCreatorController
 * @author      Auto-generated for Michigan SBDC
 * @date        2026-02-12
 */
@isTest
private class ImpactCreatorControllerTest {

    @TestSetup
    static void setup() {
        // Create Account
        Account acc = new Account(
            Name = 'Test Account',
            Start_Date__c = Date.today().addMonths(-6),
            In_Business__c = true
        );
        insert acc;

        // Create Case
        Case c = new Case(
            Subject = 'Test Case',
            AccountId = acc.Id
        );
        insert c;

        // Create Products
        Product2 prod1 = new Product2(Name = 'SBA 7(a) Loan', IsActive = true, Partner_Type__c = 'Lender');
        Product2 prod2 = new Product2(Name = 'SBA 504 Loan', IsActive = true, Partner_Type__c = 'Lender');
        insert new List<Product2>{ prod1, prod2 };

        // Create Standard Pricebook Entries
        Id stdPbId = Test.getStandardPricebookId();
        PricebookEntry pbe1 = new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = prod1.Id,
            UnitPrice = 0, IsActive = true
        );
        PricebookEntry pbe2 = new PricebookEntry(
            Pricebook2Id = stdPbId, Product2Id = prod2.Id,
            UnitPrice = 0, IsActive = true
        );
        insert new List<PricebookEntry>{ pbe1, pbe2 };
    }

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
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];
        List<Product2> prods = [SELECT Id, Name FROM Product2 ORDER BY Name];

        ImpactCreatorController.CreatePayload payload = new ImpactCreatorController.CreatePayload();
        payload.caseId = c.Id;
        payload.impactName = 'Test Impact';
        payload.attributionDate = Date.today();
        payload.stageName = 'Impact Created';
        payload.salesIncrease = 50000;
        payload.salesSource = 'New Business';
        payload.jobsCreated = 5;
        payload.jobsRetained = 10;
        payload.newBusiness = true;
        payload.boughtBusiness = false;
        payload.soldBusiness = false;
        payload.businessStartDate = null; // Use Account's

        // Capital Source Lines
        payload.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>();
        for (Product2 p : prods) {
            ImpactCreatorController.CapitalSourceLine csl = new ImpactCreatorController.CapitalSourceLine();
            csl.productId = p.Id;
            csl.productName = p.Name;
            csl.amount = 100000;
            csl.serviceDate = Date.today();
            csl.capitalSourceType = 'Lender';
            csl.quantity = 1;
            payload.capitalSourceLines.add(csl);
        }

        // Team Members
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>();
        ImpactCreatorController.TeamMemberLine tm = new ImpactCreatorController.TeamMemberLine();
        tm.userId = c.OwnerId;
        tm.role = 'Lead Consultant';
        tm.capitalFormation = 200000;
        tm.jobsCreated = 5;
        tm.jobsRetained = 10;
        tm.salesIncrease = 50000;
        payload.teamMembers.add(tm);

        Test.startTest();
        ImpactCreatorController.CreateResult result = ImpactCreatorController.createImpact(
            JSON.serialize(payload)
        );
        Test.stopTest();

        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        System.assertEquals(2, result.oliCount, 'Should have 2 OLIs');
        System.assertEquals(1, result.teamMemberCount, 'Should have 1 team member');

        // Verify data
        Opportunity opp = [SELECT Id, Name, Jobs_Created__c FROM Opportunity WHERE Id = :result.opportunityId];
        System.assertEquals('Test Impact', opp.Name);
        System.assertEquals(5, opp.Jobs_Created__c);
    }

    @isTest
    static void testSearchUsers() {
        Test.startTest();
        List<ImpactCreatorController.UserOption> users = ImpactCreatorController.searchUsers('a');
        Test.stopTest();

        // At minimum, the running user should be returned
        System.assert(users != null, 'Should return a list');
    }

    @isTest
    static void testCreateImpactAutoCreatesPricebookEntry() {
        Case c = [SELECT Id, OwnerId FROM Case LIMIT 1];

        // Create a new product WITHOUT a PricebookEntry
        Product2 newProd = new Product2(
            Name = 'New Grant Program',
            IsActive = true,
            Partner_Type__c = 'Government'
        );
        insert newProd;

        ImpactCreatorController.CreatePayload payload = new ImpactCreatorController.CreatePayload();
        payload.caseId = c.Id;
        payload.impactName = 'Test Impact Auto PBE';
        payload.attributionDate = Date.today();
        payload.stageName = 'Impact Created';
        payload.salesIncrease = 25000;
        payload.jobsCreated = 2;
        payload.jobsRetained = 3;

        // Use the product without a PricebookEntry
        payload.capitalSourceLines = new List<ImpactCreatorController.CapitalSourceLine>();
        ImpactCreatorController.CapitalSourceLine csl = new ImpactCreatorController.CapitalSourceLine();
        csl.productId = newProd.Id;
        csl.productName = newProd.Name;
        csl.amount = 50000;
        csl.serviceDate = Date.today();
        csl.quantity = 1;
        payload.capitalSourceLines.add(csl);

        // Team Members
        payload.teamMembers = new List<ImpactCreatorController.TeamMemberLine>();
        ImpactCreatorController.TeamMemberLine tm = new ImpactCreatorController.TeamMemberLine();
        tm.userId = c.OwnerId;
        tm.role = 'Lead Consultant';
        tm.capitalFormation = 50000;
        tm.jobsCreated = 2;
        tm.jobsRetained = 3;
        tm.salesIncrease = 25000;
        payload.teamMembers.add(tm);

        Test.startTest();
        ImpactCreatorController.CreateResult result = ImpactCreatorController.createImpact(
            JSON.serialize(payload)
        );
        Test.stopTest();

        System.assertNotEquals(null, result.opportunityId, 'Opportunity should be created');
        System.assertEquals(1, result.oliCount, 'Should have 1 OLI');

        // Verify PricebookEntry was auto-created
        List<PricebookEntry> pbes = [
            SELECT Id FROM PricebookEntry
            WHERE Product2Id = :newProd.Id AND Pricebook2.IsStandard = true
        ];
        System.assertEquals(1, pbes.size(), 'PricebookEntry should have been auto-created');
    }
}
