/**
 * @description Controller for the Impact Creator LWC - creates an Impact (Opportunity)
 *              from a Case with Capital Sources (OLIs) and Team Members.
 *              Replaces the screen flow "New_Impact_Create_Impact_from_Case".
 * @author      Auto-generated for Michigan SBDC
 * @date        2026-02-12
 * @modified    2026-03-11 - MJD (MSBDC-93 Phase 1)
 *              Added Target_Impact__c stamping on OpportunityTeamMember insert.
 *              After Team Members are created, resolves matching Target__c records
 *              (by Consultant UserId + Target_Year, or by Account + Target_Year for
 *              Center/Region targets) and stamps Target_Impact__c = Target__c.Id.
 *              This enables the rebuilt Target_Rollups flow to use ID-based matching
 *              instead of the fragile Center_Region__c name-match approach.
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
        @AuraEnabled public List<PicklistOption> capitalSourceTypeOptions;
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
        @AuraEnabled public Date businessStartDate;
        @AuraEnabled public List<CapitalSourceLine> capitalSourceLines;
        @AuraEnabled public List<TeamMemberLine> teamMembers;
        @AuraEnabled public String impactAttributionYear;
    }

    public class CapitalSourceLine {
        @AuraEnabled public String productId;
        @AuraEnabled public String productName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public Date serviceDate;
        @AuraEnabled public String capitalSourceType;
        @AuraEnabled public String capitalSourcePartnerId;
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

        data.caseRecord = [
            SELECT Id, CaseNumber, AccountId, OwnerId,
                   Account.Name, Account.Start_Date__c, Account.In_Business__c,
                   Owner.Name, Owner.FirstName, Owner.LastName
            FROM Case
            WHERE Id = :caseId
            LIMIT 1
        ];

        data.caseOwnerName    = data.caseRecord.Owner.Name;
        data.accountName      = data.caseRecord.Account?.Name;
        data.accountStartDate = data.caseRecord.Account?.Start_Date__c;
        data.accountInBusiness = data.caseRecord.Account?.In_Business__c;

        data.capitalSources = [
            SELECT Id, Name, Family, Sub_Type__c, Partner_Type__c, Description
            FROM Product2
            WHERE IsActive = true
            ORDER BY Name ASC
        ];

        data.stageOptions            = getPicklistValues('Opportunity', 'StageName');
        data.salesSourceOptions      = getPicklistValues('Opportunity', 'Sales_Source__c');
        data.teamRoleOptions         = getPicklistValues('OpportunityTeamMember', 'TeamMemberRole');
        data.partnerTypeOptions      = getPicklistValues('Product2', 'Partner_Type__c');
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

            // 2. Get Case for OwnerId & Account linkage
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
                Name               = payload.impactName,
                AccountId          = c.AccountId,
                OwnerId            = c.OwnerId,
                Case__c            = c.Id,
                CloseDate          = payload.attributionDate,
                StageName          = payload.stageName,
                Sales_Increase__c  = payload.salesIncrease,
                Sales_Source__c    = String.isNotBlank(payload.salesSource) ? payload.salesSource : null,
                Jobs_Created__c    = payload.jobsCreated,
                Jobs_Retained__c   = payload.jobsRetained,
                New_Business__c    = payload.newBusiness == true,
                Bought_Business__c = payload.boughtBusiness == true,
                Sold_Business__c   = payload.soldBusiness == true,
                Business_Start_Date__c = bizStartDate,
                Pricebook2Id       = stdPb.Id
            );
            insert opp;

            // 4. Create OLIs (Capital Sources)
            Integer oliCount = 0;
            if (payload.capitalSourceLines != null && !payload.capitalSourceLines.isEmpty()) {

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

                List<OpportunityLineItem> olis = new List<OpportunityLineItem>();
                for (CapitalSourceLine csl : payload.capitalSourceLines) {
                    Id pbeId = prodToPbeId.get(csl.productId);
                    if (pbeId == null) {
                        throw new AuraHandledException(
                            'No active Pricebook Entry found for product: ' + csl.productName +
                            '. Please ensure it has an entry in the Standard Pricebook.'
                        );
                    }
                    OpportunityLineItem oli = new OpportunityLineItem(
                        OpportunityId    = opp.Id,
                        Product2Id       = csl.productId,
                        PricebookEntryId = pbeId,
                        UnitPrice        = csl.amount != null ? csl.amount : 0,
                        Quantity         = csl.quantity != null ? csl.quantity : 1,
                        ServiceDate      = csl.serviceDate
                    );
                    if (String.isNotBlank(csl.capitalSourceType)) {
                        oli.Capital_Source_Type__c = csl.capitalSourceType;
                    }
                    if (String.isNotBlank(csl.capitalSourcePartnerId) &&
                        csl.capitalSourcePartnerId instanceof Id) {
                        oli.Capital_Source__c = csl.capitalSourcePartnerId;
                    }
                    olis.add(oli);
                }
                insert olis;
                oliCount = olis.size();
            }

            // 5. Derive attribution year
            String attrYear = String.valueOf(payload.attributionDate.year());

            // 6. Build and insert Team Member records
            List<OpportunityTeamMember> tms = new List<OpportunityTeamMember>();

            if (payload.teamMembers != null && !payload.teamMembers.isEmpty()) {
                for (TeamMemberLine tml : payload.teamMembers) {
                    tms.add(new OpportunityTeamMember(
                        OpportunityId            = opp.Id,
                        UserId                   = tml.userId,
                        TeamMemberRole           = tml.role,
                        OpportunityAccessLevel   = 'Edit',
                        Capital_Formation__c     = tml.capitalFormation != null ? tml.capitalFormation : 0,
                        Jobs_Created__c          = tml.jobsCreated != null ? tml.jobsCreated : 0,
                        Jobs_Retained__c         = tml.jobsRetained != null ? tml.jobsRetained : 0,
                        Sales_Increase__c        = tml.salesIncrease != null ? tml.salesIncrease : 0,
                        Impact_Attribution_Year__c = attrYear
                    ));
                }
            } else {
                // Auto-add Case Owner as Lead Consultant when no team members provided
                tms.add(new OpportunityTeamMember(
                    OpportunityId            = opp.Id,
                    UserId                   = c.OwnerId,
                    TeamMemberRole           = 'Lead Consultant',
                    OpportunityAccessLevel   = 'Edit',
                    Capital_Formation__c     = 0,
                    Jobs_Created__c          = payload.jobsCreated != null ? payload.jobsCreated : 0,
                    Jobs_Retained__c         = payload.jobsRetained != null ? payload.jobsRetained : 0,
                    Sales_Increase__c        = payload.salesIncrease != null ? payload.salesIncrease : 0,
                    Impact_Attribution_Year__c = attrYear
                ));
            }

            insert tms;

            // 7. Stamp Target_Impact__c on the inserted team members
            //    Resolves the Current Target__c for each team member's UserId + year,
            //    enabling the rebuilt Target_Rollups flow to use ID-based matching
            //    rather than the fragile Center_Region__c name-match approach.
            stampTargetImpact(tms, attrYear);

            // 8. Return result
            CreateResult result = new CreateResult();
            result.opportunityId   = opp.Id;
            result.opportunityName = opp.Name;
            result.oliCount        = oliCount;
            result.teamMemberCount = tms.size();
            return result;

        } catch (AuraHandledException ahe) {
            Database.rollback(sp);
            throw ahe;
        } catch (Exception e) {
            Database.rollback(sp);
            String msg = e.getMessage();
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

    // ── Target Stamping ────────────────────────────────────────────────

    /**
     * @description After inserting OpportunityTeamMember records, resolves the
     *              matching Current Target__c for each team member's UserId + year
     *              and stamps Target_Impact__c accordingly.
     *
     *              Logic:
     *              - Collects the distinct set of UserIds from inserted tms
     *              - Queries Target__c WHERE RecordType = Consultant
     *                AND Consultant_Name__c IN :userIds
     *                AND Target_Year__c = :attrYear
     *                AND Status__c = 'Current'
     *              - Builds a Map<UserId, Target__c.Id>
     *              - Updates any tms where a matching Target is found
     *
     *              Targets where no match is found are left with Target_Impact__c = null
     *              and are skipped gracefully (no exception thrown). This handles
     *              years where Targets have not yet been created, or consultants
     *              who have no Target record for the given year.
     *
     * @param tms       The already-inserted OpportunityTeamMember list (with Ids)
     * @param attrYear  The attribution year string (e.g. '2026')
     */
    @TestVisible
    private static void stampTargetImpact(
        List<OpportunityTeamMember> tms,
        String attrYear
    ) {
        if (tms == null || tms.isEmpty()) {
            return;
        }

        // Collect distinct UserIds
        Set<Id> userIds = new Set<Id>();
        for (OpportunityTeamMember tm : tms) {
            userIds.add(tm.UserId);
        }

        // Query matching Consultant Targets for this year
        // Uses Target_Year__c (Formula Text, e.g. '2026') as the year key —
        // same field the Target_Rollups flow already filters on.
        Map<Id, Id> userIdToTargetId = new Map<Id, Id>();
        for (Target__c t : [
            SELECT Id, Consultant_Name__c
            FROM Target__c
            WHERE Consultant_Name__c IN :userIds
              AND Target_Year__c = :attrYear
              AND Status__c = 'Current'
              AND RecordType.DeveloperName = 'Consultant'
        ]) {
            // Last-write wins in the unlikely case of duplicate Targets per
            // consultant per year — duplicate prevention is enforced separately
            // via validation rules (Phase 1 task).
            userIdToTargetId.put(t.Consultant_Name__c, t.Id);
        }

        // Nothing to stamp — no matching Targets found (e.g. Targets not yet
        // created for this year). Exit gracefully.
        if (userIdToTargetId.isEmpty()) {
            return;
        }

        // Build update list — only update tms where a Target was found
        List<OpportunityTeamMember> toUpdate = new List<OpportunityTeamMember>();
        for (OpportunityTeamMember tm : tms) {
            Id targetId = userIdToTargetId.get(tm.UserId);
            if (targetId != null) {
                toUpdate.add(new OpportunityTeamMember(
                    Id               = tm.Id,
                    Target_Impact__c = targetId
                ));
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    // ── User Search ────────────────────────────────────────────────────

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
            this.userId   = userId;
            this.name     = name;
            this.photoUrl = photoUrl;
            this.title    = title;
        }
    }

    // ── Account Search ─────────────────────────────────────────────────

    @AuraEnabled(cacheable=true)
    public static List<AccountOption> searchAccounts(String searchTerm) {
        String term = '%' + String.escapeSingleQuotes(searchTerm) + '%';
        List<AccountOption> results = new List<AccountOption>();

        Id partnerRtId;
        List<RecordType> rts = [
            SELECT Id FROM RecordType
            WHERE SObjectType = 'Account'
              AND DeveloperName = 'Partner_Organization'
              AND IsActive = true
            LIMIT 1
        ];
        if (rts.isEmpty()) {
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
            this.name      = name;
        }
    }

    // ── Helpers ────────────────────────────────────────────────────────

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
