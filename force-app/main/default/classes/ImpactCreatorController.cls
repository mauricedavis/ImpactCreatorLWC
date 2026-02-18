/**
 * @description Controller for the Impact Creator LWC - creates an Impact (Opportunity)
 *              from a Case with Capital Sources (OLIs) and Team Members.
 *              Replaces the screen flow "New_Impact_Create_Impact_from_Case".
 * @author      Auto-generated for Michigan SBDC
 * @date        2026-02-12
 */
public with sharing class ImpactCreatorController {

    // ── Data Transfer Objects ──────────────────────────────────────────

    /**
     * Wrapper returned when the LWC initialises — contains everything
     * the component needs to render the form.
     */
    public class InitData {
        @AuraEnabled public Case caseRecord;
        @AuraEnabled public String caseOwnerName;
        @AuraEnabled public String accountName;
        @AuraEnabled public Date accountStartDate;
        @AuraEnabled public Boolean accountInBusiness;
        @AuraEnabled public List<Product2> capitalSources;
        @AuraEnabled public List<PicklistOption> stageOptions;
        @AuraEnabled public List<PicklistOption> salesSourceOptions;
        @AuraEnabled public List<PicklistOption> teamRoleOptions;
        @AuraEnabled public List<PicklistOption> partnerTypeOptions;
        @AuraEnabled public List<PicklistOption> capitalSourceTypeOptions; // OLI-level picklist
    }

    public class PicklistOption {
        @AuraEnabled public String label;
        @AuraEnabled public String value;
        public PicklistOption(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    /**
     * Payload sent from the LWC when the user clicks "Create Impact".
     */
    public class CreatePayload {
        @AuraEnabled public String caseId;
        @AuraEnabled public String impactName;
        @AuraEnabled public Date attributionDate;
        @AuraEnabled public String stageName;
        @AuraEnabled public Decimal salesIncrease;
        @AuraEnabled public String salesSource;
        @AuraEnabled public Integer jobsCreated;
        @AuraEnabled public Integer jobsRetained;
        @AuraEnabled public Boolean newBusiness;
        @AuraEnabled public Boolean boughtBusiness;
        @AuraEnabled public Boolean soldBusiness;
        @AuraEnabled public Date businessStartDate; // null = use Account's
        @AuraEnabled public List<CapitalSourceLine> capitalSourceLines;
        @AuraEnabled public List<TeamMemberLine> teamMembers;
        @AuraEnabled public String impactAttributionYear; // derived from attributionDate
    }

    public class CapitalSourceLine {
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date serviceDate;
        @AuraEnabled public String capitalSourceType; // Partner_Type__c value
        @AuraEnabled public String capitalSourcePartnerId; // Account Id
        @AuraEnabled public Decimal quantity;
    }

    public class TeamMemberLine {
        @AuraEnabled public String userId;
        @AuraEnabled public String userName;
        @AuraEnabled public String role;
        @AuraEnabled public Decimal capitalFormation;
        @AuraEnabled public Integer jobsCreated;
        @AuraEnabled public Integer jobsRetained;
        @AuraEnabled public Decimal salesIncrease;
    }

    public class CreateResult {
        @AuraEnabled public String opportunityId;
        @AuraEnabled public String opportunityName;
        @AuraEnabled public Integer oliCount;
        @AuraEnabled public Integer teamMemberCount;
    }

    // ── Init ───────────────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static InitData getInitData(String caseId) {
        InitData data = new InitData();

        // Get Case with related Account and Owner info
        data.caseRecord = [
            SELECT Id, CaseNumber, AccountId, OwnerId,
                   Account.Name, Account.Start_Date__c, Account.In_Business__c,
                   Owner.Name, Owner.FirstName, Owner.LastName
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];

        data.caseOwnerName = data.caseRecord.Owner.Name;
        data.accountName = data.caseRecord.Account?.Name;
        data.accountStartDate = data.caseRecord.Account?.Start_Date__c;
        data.accountInBusiness = data.caseRecord.Account?.In_Business__c;

        // Get all active Capital Sources (Product2)
        data.capitalSources = [
            SELECT Id, Name, Family, Sub_Type__c, Partner_Type__c, Description
            FROM Product2
            WHERE IsActive = true
            ORDER BY Name ASC
        ];

        // Picklist values
        data.stageOptions = getPicklistValues('Opportunity', 'StageName');
        data.salesSourceOptions = getPicklistValues('Opportunity', 'Sales_Source__c');
        data.teamRoleOptions = getPicklistValues('OpportunityTeamMember', 'TeamMemberRole');
        data.partnerTypeOptions = getPicklistValues('Product2', 'Partner_Type__c');
        data.capitalSourceTypeOptions = getPicklistValues('OpportunityLineItem', 'Capital_Source_Type__c');

        return data;
    }

    // ── Create Impact ──────────────────────────────────────────────────

    @AuraEnabled
    public static CreateResult createImpact(String payloadJson) {
        CreatePayload payload = (CreatePayload) JSON.deserialize(payloadJson, CreatePayload.class);

        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Resolve Pricebook
            Pricebook2 stdPb = [
                SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1
            ];

            // 2. Get Case for OwnerId & Account Start Date
            Case c = [
                SELECT Id, AccountId, OwnerId, Account.Start_Date__c
                FROM Case
                WHERE Id = :payload.caseId
                LIMIT 1
            ];

            // Determine Business Start Date
            Date bizStartDate = payload.businessStartDate != null
                ? payload.businessStartDate
                : c.Account?.Start_Date__c;

            // 3. Create Opportunity (Impact)
            Opportunity opp = new Opportunity(
                Name              = payload.impactName,
                AccountId         = c.AccountId,
                OwnerId           = c.OwnerId,
                Case__c           = c.Id,
                CloseDate         = payload.attributionDate,
                StageName         = payload.stageName,
                Sales_Increase__c = payload.salesIncrease,
                Sales_Source__c   = String.isNotBlank(payload.salesSource) ? payload.salesSource : null,
                Jobs_Created__c   = payload.jobsCreated,
                Jobs_Retained__c  = payload.jobsRetained,
                New_Business__c   = payload.newBusiness == true,
                Bought_Business__c = payload.boughtBusiness == true,
                Sold_Business__c  = payload.soldBusiness == true,
                Business_Start_Date__c = bizStartDate,
                Pricebook2Id      = stdPb.Id
            );
            insert opp;

            // 4. Create OLIs (Capital Sources)
            Integer oliCount = 0;
            if (payload.capitalSourceLines != null && !payload.capitalSourceLines.isEmpty()) {
                // Bulk-query PricebookEntries for all selected products
                Set<String> productIds = new Set<String>();
                for (CapitalSourceLine csl : payload.capitalSourceLines) {
                    productIds.add(csl.productId);
                }

                Map<String, Id> prodToPbeId = new Map<String, Id>();
                for (PricebookEntry pbe : [
                    SELECT Id, Product2Id
                    FROM PricebookEntry
                    WHERE Product2Id IN :productIds
                      AND Pricebook2Id = :stdPb.Id
                      AND IsActive = true
                ]) {
                    prodToPbeId.put(pbe.Product2Id, pbe.Id);
                }

                // Auto-create missing PricebookEntries for products that don't have them
                Set<String> missingProductIds = new Set<String>();
                for (String prodId : productIds) {
                    if (!prodToPbeId.containsKey(prodId)) {
                        missingProductIds.add(prodId);
                    }
                }

                if (!missingProductIds.isEmpty()) {
                    List<PricebookEntry> newPbes = new List<PricebookEntry>();
                    for (String prodId : missingProductIds) {
                        newPbes.add(new PricebookEntry(
                            Pricebook2Id = stdPb.Id,
                            Product2Id = prodId,
                            UnitPrice = 0,
                            IsActive = true
                        ));
                    }
                    insert newPbes;

                    // Add newly created PBEs to the map
                    for (PricebookEntry pbe : newPbes) {
                        prodToPbeId.put(pbe.Product2Id, pbe.Id);
                    }
                }

                List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
                for (CapitalSourceLine csl : payload.capitalSourceLines) {
                    Id pbeId = prodToPbeId.get(csl.productId);

                    OpportunityLineItem oli = new OpportunityLineItem(
                        OpportunityId      = opp.Id,
                        Product2Id         = csl.productId,
                        PricebookEntryId   = pbeId,
                        UnitPrice          = csl.amount != null ? csl.amount : 0,
                        Quantity           = csl.quantity != null ? csl.quantity : 1,
                        ServiceDate        = csl.serviceDate
                    );

                    // Only set Capital Source Type if non-blank
                    if (String.isNotBlank(csl.capitalSourceType)) {
                        oli.Capital_Source_Type__c = csl.capitalSourceType;
                    }

                    // Only set Capital Source Partner if it's a valid Id
                    if (String.isNotBlank(csl.capitalSourcePartnerId) &&
                        csl.capitalSourcePartnerId instanceof Id) {
                        oli.Capital_Source__c = csl.capitalSourcePartnerId;
                    }

                    olis.add(oli);
                }
                insert olis;
                oliCount = olis.size();
            }

            // 5. Create Team Members
            Integer tmCount = 0;
            if (payload.teamMembers != null && !payload.teamMembers.isEmpty()) {
                // Derive attribution year from the close date
                String attrYear = String.valueOf(payload.attributionDate.year());

                List<OpportunityTeamMember> tms = new List<OpportunityTeamMember>();
                for (TeamMemberLine tml : payload.teamMembers) {
                    System.debug('=== Team Member: ' + tml.userName + ' ===');
                    System.debug('Capital Formation: ' + tml.capitalFormation);
                    System.debug('Jobs Created: ' + tml.jobsCreated);
                    System.debug('Jobs Retained: ' + tml.jobsRetained);
                    System.debug('Sales Increase: ' + tml.salesIncrease);

                    tms.add(new OpportunityTeamMember(
                        OpportunityId        = opp.Id,
                        UserId               = tml.userId,
                        TeamMemberRole       = tml.role,
                        OpportunityAccessLevel = 'Edit',
                        Capital_Formation__c = tml.capitalFormation != null ? tml.capitalFormation : 0,
                        Jobs_Created__c      = tml.jobsCreated != null ? tml.jobsCreated : 0,
                        Jobs_Retained__c     = tml.jobsRetained != null ? tml.jobsRetained : 0,
                        Sales_Increase__c    = tml.salesIncrease != null ? tml.salesIncrease : 0,
                        Impact_Attribution_Year__c = attrYear
                    ));
                }
                insert tms;
                tmCount = tms.size();
            }

            // 6. Return result
            CreateResult result = new CreateResult();
            result.opportunityId = opp.Id;
            result.opportunityName = opp.Name;
            result.oliCount = oliCount;
            result.teamMemberCount = tmCount;
            return result;

        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe; // Already properly formatted
        } catch (Exception e) {
            Database.rollback(sp);
            String msg = e.getMessage();
            // Include DML field errors if available
            if (e instanceof DmlException) {
                DmlException dml = (DmlException) e;
                msg = '';
                for (Integer i = 0; i < dml.getNumDml(); i++) {
                    msg += dml.getDmlMessage(i);
                    if (i < dml.getNumDml() - 1) msg += '; ';
                }
            }
            AuraHandledException ahe = new AuraHandledException(msg);
            ahe.setMessage(msg);
            throw ahe;
        }
    }

    // ── User Search (for team member lookup) ───────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<UserOption> searchUsers(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<UserOption> results = new List<UserOption>();
        for (User u : [
            SELECT Id, Name, SmallPhotoUrl, Title
            FROM User
            WHERE IsActive = true
              AND UserType = 'Standard'
              AND (Name LIKE :term OR Email LIKE :term)
            ORDER BY Name ASC
            LIMIT 20
        ]) {
            results.add(new UserOption(u.Id, u.Name, u.SmallPhotoUrl, u.Title));
        }
        return results;
    }

    public class UserOption {
        @AuraEnabled public String userId;
        @AuraEnabled public String name;
        @AuraEnabled public String photoUrl;
        @AuraEnabled public String title;
        public UserOption(String userId, String name, String photoUrl, String title) {
            this.userId = userId;
            this.name = name;
            this.photoUrl = photoUrl;
            this.title = title;
        }
    }

    // ── Account Search (for Capital Source Partner lookup) ────────────

    @AuraEnabled(cacheable=true)
    public static List<AccountOption> searchAccounts(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<AccountOption> results = new List<AccountOption>();

        // Get the Partner Organization record type Id
        Id partnerRtId;
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account'
              AND DeveloperName = 'Partner_Organization'
              AND IsActive = true
            LIMIT 1
        ];
        if (rts.isEmpty()) {
            // Fallback: try by Name
            rts = [
                SELECT Id FROM RecordType
                WHERE SObjectType = 'Account'
                  AND Name = 'Partner Organization'
                  AND IsActive = true
                LIMIT 1
            ];
        }
        if (!rts.isEmpty()) {
            partnerRtId = rts[0].Id;
        }

        String query = 'SELECT Id, Name FROM Account WHERE Name LIKE :term';
        if (partnerRtId != null) {
            query += ' AND RecordTypeId = :partnerRtId';
        }
        query += ' ORDER BY Name ASC LIMIT 20';

        for (Account a : Database.query(query)) {
            results.add(new AccountOption(a.Id, a.Name));
        }
        return results;
    }

    public class AccountOption {
        @AuraEnabled public String accountId;
        @AuraEnabled public String name;
        public AccountOption(String accountId, String name) {
            this.accountId = accountId;
            this.name = name;
        }
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    private static List<PicklistOption> getPicklistValues(String objectName, String fieldName) {
        List<PicklistOption> options = new List<PicklistOption>();
        Schema.DescribeFieldResult dfr = Schema.getGlobalDescribe()
            .get(objectName)
            .getDescribe()
            .fields.getMap()
            .get(fieldName)
            .getDescribe();
        for (Schema.PicklistEntry pe : dfr.getPicklistValues()) {
            if (pe.isActive()) {
                options.add(new PicklistOption(pe.getLabel(), pe.getValue()));
            }
        }
        return options;
    }
}
