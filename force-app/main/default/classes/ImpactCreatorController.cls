/**
 * @description Controller for the Impact Creator LWC - creates an Impact (Opportunity)
 *              from a Case with Capital Sources (OLIs) and Team Members.
 *              Replaces the screen flow "New_Impact_Create_Impact_from_Case".
 * @author      Auto-generated for Michigan SBDC
 * @date        2026-02-12
 * @modified    2026-03-11 - MJD (MSBDC-93 Phase 1)
 *              Added Target_Impact__c stamping on OpportunityTeamMember insert.
 * @modified    2026-09-01 - MJD/Claude (MSBDC-93 Consultant/Region parity fix)
 *              Corrected a bug where stampTargetImpact() wrote the Consultant Target
 *              match into Target_Impact__c -- which silently broke the Center/Region
 *              rollup for every new Impact once Target_Rollups was rebuilt to expect
 *              Target_Impact__c to point to a Region/Center Target. Two lookup fields
 *              are now used, since a team member legitimately matches both
 *              simultaneously:
 *              - Target_Impact__c: the Region/Center Target, resolved via
 *                TargetImpactResolver.resolveTargetIds() against the Case's
 *                Account's parent Region/Center Account (stampRegionTargetImpact()).
 *                This is a genuinely new capability -- it did not exist before this
 *                fix, so new Impacts previously never populated this field at all.
 *              - Consultant_Target_Impact__c: the Consultant Target, resolved via
 *                the new TargetImpactResolver.resolveConsultantTargetIds() against
 *                the team member's UserId (stampTargetImpact(), renamed target field
 *                only -- matching logic unchanged except Status__c = 'Current' is no
 *                longer filtered, for the same reason it was never filtered in
 *                resolveTargetIds()).
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

        // MSBDC-108: New Impacts cannot be created directly at "Impact Verified" --
        // that path bypassed Verification_by_manager_only (ISCHANGED() is false on
        // insert) and enabled self-verification. Excluded here so the wizard never
        // offers it as a Step 1 starting stage. Block_verified_on_New_Impact (Opportunity
        // validation rule) remains the server-side backstop if this is ever bypassed.
        data.stageOptions            = excludeStage(getPicklistValues('Opportunity', 'StageName'), 'Impact Verified');
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

        // MSBDC-108: server-side guard, defense in depth against payload tampering --
        // Step 1 no longer offers "Impact Verified" as a stage option, and
        // Block_verified_on_New_Impact enforces this at the database layer too, but
        // this gives a clean, friendly error instead of a raw validation-rule DML
        // exception if the client payload is ever manipulated to bypass the UI.
        if (payload.stageName == 'Impact Verified') {
            String msg = 'New Impacts cannot be created directly at the Impact Verified stage. ' +
                'Save the Impact at an earlier stage first, then verify it as a separate step.';
            AuraHandledException ex = new AuraHandledException(msg);
            ex.setMessage(msg); // required -- the constructor arg alone isn't surfaced via getMessage()
            throw ex;
        }

        Savepoint sp = Database.setSavepoint();
        try {
            // 1. Resolve Pricebook
            // Note: querying IsStandard = true returns no rows in test context.
            // Test.getStandardPricebookId() works in both test and non-test contexts.
            Id stdPbId = Test.isRunningTest()
                ? Test.getStandardPricebookId()
                : [SELECT Id FROM Pricebook2 WHERE IsStandard = true LIMIT 1].Id;

            // 2. Get Case for OwnerId & Account linkage
            Case c = [
                SELECT Id, AccountId, OwnerId, Account.Start_Date__c,
                       Account.Center_Region__c
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
                Pricebook2Id       = stdPbId
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
                      AND Pricebook2Id = :stdPbId
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

            // 7. Stamp Target_Impact__c (Region/Center) and Consultant_Target_Impact__c
            //    (Consultant) on the inserted team members. These are two distinct
            //    lookup fields -- a single team member legitimately contributes to
            //    both their consultant's personal Target AND their Region/Center's
            //    Target simultaneously (MSBDC-93 Consultant/Region parity fix).
            stampRegionTargetImpact(tms, attrYear, c.Account?.Center_Region__c);
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
     *              matching Current Consultant Target__c for each team member's
     *              UserId + year and stamps Consultant_Target_Impact__c accordingly.
     *
     *              NOTE: this stamps Consultant_Target_Impact__c, NOT Target_Impact__c.
     *              Target_Impact__c is reserved for the Region/Center match (see
     *              stampRegionTargetImpact() below) -- a single team member
     *              contributes to both simultaneously, so each needs its own field.
     *              (Prior to MSBDC-93's Consultant/Region parity fix, this method
     *              incorrectly wrote the Consultant match into Target_Impact__c,
     *              which silently broke the Center/Region rollup for every new
     *              Impact created after the flow was rebuilt to expect Target_Impact__c
     *              to point to a Region/Center Target.)
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
     *              Targets where no match is found are left with
     *              Consultant_Target_Impact__c = null and are skipped gracefully (no
     *              exception thrown). This handles years where Targets have not yet
     *              been created, or consultants who have no Target record for the
     *              given year.
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

        // Resolve matching Consultant Targets for this year via the shared
        // TargetImpactResolver utility, so new records and backfilled historical
        // records (BackfillConsultantTargetImpactBatch) resolve identically.
        Map<String, Id> resolved = TargetImpactResolver.resolveConsultantTargetIds(userIds, new Set<String>{ attrYear });

        // Nothing to stamp — no matching Targets found (e.g. Targets not yet
        // created for this year). Exit gracefully.
        if (resolved.isEmpty()) {
            return;
        }

        // Build update list — only update tms where a Target was found
        List<OpportunityTeamMember> toUpdate = new List<OpportunityTeamMember>();
        for (OpportunityTeamMember tm : tms) {
            String key = TargetImpactResolver.buildConsultantKey(tm.UserId, attrYear);
            Id targetId = resolved.get(key);
            if (targetId != null) {
                toUpdate.add(new OpportunityTeamMember(
                    Id                          = tm.Id,
                    Consultant_Target_Impact__c = targetId
                ));
            }
        }

        if (!toUpdate.isEmpty()) {
            update toUpdate;
        }
    }

    /**
     * @description After inserting OpportunityTeamMember records, resolves the
     *              matching Current Region/Center Target__c for the Case's Account's
     *              parent Region/Center Account + year, and stamps Target_Impact__c
     *              on every inserted team member. Uses the same TargetImpactResolver
     *              utility as BackfillTargetImpactBatch, so new records and
     *              backfilled historical records resolve identically (MSBDC-93).
     *
     *              This is a genuinely new capability as of this fix -- previously,
     *              new Impacts created via this wizard never had Target_Impact__c
     *              populated at all, so they were silently excluded from
     *              Target_Rollups' Center/Region rollup (Find_Region_Impact_Records)
     *              even after that flow was rebuilt to use ID-based matching.
     *
     * @param tms                    The already-inserted OpportunityTeamMember list
     * @param attrYear               The attribution year string (e.g. '2026')
     * @param centerRegionAccountId  The Region/Center Account Id, derived from the
     *                                Case's Account (Account.Center_Region__c). May
     *                                be null if the client Account has no Region/
     *                                Center assigned, in which case this is skipped
     *                                gracefully.
     */
    @TestVisible
    private static void stampRegionTargetImpact(
        List<OpportunityTeamMember> tms,
        String attrYear,
        Id centerRegionAccountId
    ) {
        if (tms == null || tms.isEmpty() || centerRegionAccountId == null) {
            return;
        }

        Map<String, Id> resolved = TargetImpactResolver.resolveTargetIds(
            new Set<Id>{ centerRegionAccountId },
            new Set<String>{ attrYear }
        );

        Id targetId = resolved.get(TargetImpactResolver.buildKey(centerRegionAccountId, attrYear));

        // No matching Region/Center Target for this year -- skip gracefully, same
        // as stampTargetImpact() does for the Consultant path.
        if (targetId == null) {
            return;
        }

        List<OpportunityTeamMember> toUpdate = new List<OpportunityTeamMember>();
        for (OpportunityTeamMember tm : tms) {
            toUpdate.add(new OpportunityTeamMember(
                Id               = tm.Id,
                Target_Impact__c = targetId
            ));
        }

        update toUpdate;
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

    // MSBDC-108: filters a specific value out of a picklist option list -- used to
    // keep "Impact Verified" from being offered as a Step 1 starting stage.
    private static List<PicklistOption> excludeStage(List<PicklistOption> options, String valueToExclude) {
        List<PicklistOption> filtered = new List<PicklistOption>();
        for (PicklistOption o : options) {
            if (o.value != valueToExclude) {
                filtered.add(o);
            }
        }
        return filtered;
    }
}
