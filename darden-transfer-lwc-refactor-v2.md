# Darden Transfer Subflow → LWC Refactoring Guide (Updated)

## 1. Current Architecture Overview

### Parent Flow: `Cancellations_Transfers_Substitution`
This is the **parent orchestrator** flow that routes to three subflows based on user selection:

```
Start → Screen: "Registration Change Request"
         (Radio: Cancellation / Substitution / Transfer)
              │
              ▼
         Get Reg Opp (lookup Opportunity from Attendee)
              │
              ▼
         Type Decision
         ├── Cancellation → Cancellations_Subflow
         ├── Transfer     → Transfer_Subflow
         └── Default      → Substitution_Subflow
```

**Input Variable:** `OriginalAttendee` (evt__Attendee__c) — passed to all subflows.

**Key Formula:**
```
PaymentOpp = IF(Has_Parent_Opportunity__c = "Yes", Parent_Opportunity__c, Id)
```
This determines whether payment sits on the Opp itself or a parent (bundled registration).

---

## 2. Cancellations Subflow — Full Analysis (Pattern to Mirror)

### Flow Structure
```
Start
  → Get Reg Opp
  → Get Standard Price Book ID
  → Screen: Cancel Fee Screen
     - Shows payment status & fee amount
     - Radio: Add Cancelation Fee? (Yes/No)
     - Input: Cancelation Fee amount (if Yes)
     - Textarea: Cancel Request Comments
  → Set Cancel Registration (Attendee.evt__Invitation_Status__c = "Cancelled")
  → Update Reg (update Attendee)
  → Decision: Cancelation Fees?
     ├── Yes Fees → Set Cancel Fee → Get Cancellation Fee Product → Get PBE → Create Cancel Fee Line Item
     │             → Screen: Text1 ("Adding cancellation fees...")
     └── No Fees ──┘
  → Decision: Payment Status
     ├── Paid               → Get Paid Payment → Decision: Cancel Fees for Paid?
     ├── Partial (Bundle)   → Get Paid Payment     ├── Yes → Get "Cancelation Fee Payment Credit" Product
     ├── Partial (Standalone)→ Get Paid Payment     │        → Get PBE → Create "Cancel Fee Paid Line Item" (NEGATIVE)
     └── Not Paid           → Get Not Paid Payment  └── No  ──┘
                               → Get "Canceled" Product     │
                               → Get PBE                    ▼
                               → Create Cancel Credit OLI   Screen: Cancel Confirmation
                               → Decision: Delete/Update Payment   - Shows payment details & days since payment
                                  ├── Cancel Payment (no fee, no parent)   - Radio: Settlement Type
                                  │   → Update Payment Status = "Cancelled"     (Refund / Unapplied Funds / Apply to Balance)
                                  └── Default                               │
                                      → Set New Payment Amount              ▼
                                      → Update Payment                Decision: Settlement Type
                                                                      ├── Refund → Get "Refund" Product → Create Refund OLI → Create Refund Task
                                                                      ├── Unapplied Funds → Get "Transfer to Unapplied Funds" Product
                                                                      │                   → Create Move to Unassigned Funds OLI
                                                                      │                   → Create Unapplied_Funds__c record
                                                                      └── Default → Get "Cancelation Credit" Product → Create Credit OLI
  → Set Opp fields (Stage, Reg Change Date, Processed By, Registration Change Type, Comments)
  → Decision: Has Parent Opp?
     ├── Yes → Get Parent → Set Parent Revise_Invoice__c = true → Update Parent
     └── No  ──┘
  → Set Revise_Invoice__c = true
  → Update Opp Status
  → Screen: Cancelation Completed (with refund reminder link if applicable)
```

### Key Formulas in Cancel Flow
| Formula | Expression | Purpose |
|---------|-----------|---------|
| `CancelationFeeCredit` | `0 - CancelationFee` | Negates the fee for credit line item |
| `fCancelAmount` | `0 - Get_Reg_Opp.Amount` | Negates full opp amount for cancel credit |
| `NewPaymentAmount` | `Payment.Amount - Opp.Amount + CancelationFee` | Recalculates payment after cancel |
| `RefundAmount` | `IF(ISBLANK(vCancelationFee), Opp.Amount, Opp.Amount - vCancelationFee)` | Refund = Amount minus any cancel fee |
| `RefundAmount_Negative` | `0 - RefundAmount` | Negative for OLI credit |
| `PaymentOpp` | `IF(Has_Parent = "Yes", Parent_Opp_Id, Opp.Id)` | Payment lives on parent or self |

---

## 3. Product Catalog for Transfer/Cancel Operations

| Product Name | Product Code | Product2 Id | Active | UnitPrice Pattern | Description |
|-------------|-------------|-------------|--------|-------------------|-------------|
| **Registration Fee Credit** | `REGCRED` | `01t6T000006QSoCQAW` | ✅ | **Negative** (e.g., -$500) | Credits toward program registration costs on cancel/transfer |
| **Transfer Fee** | — | `01t6T000005nbIdQAI` | ✅ | **Positive** (e.g., $500) | Fee charged for transfer |
| **Cancelation Fees** | `CANCEL` | `01t6T000005nbGbQAI` | ✅ | **Positive** | Fee charged for cancellation |
| **Cancelation Fee Payment Credit** | — | `01t6T000005nbGlQAI` | ✅ | **Negative** | Offsets cancel fee when already paid |
| **Canceled** | — | `01t6T000005nbGmQAI` | ✅ | **Negative** (0 - Opp.Amount) | Zeros out unpaid canceled registration |
| **Cancelation Credit** | — | `01t6T000005nbGkQAI` | ✅ | **Negative** | Previously paid amount applied to balance |
| **Refund** | `REFUND` | `01t6T000005nbGfQAI` | ✅ | **Negative** | Refund line item |
| **Transfer to Unapplied Funds** | `UAFUNDS` | `01t6T000005nbGiQAI` | ❌ Inactive | **Negative** | Moves funds to unapplied |

---

## 4. Payment Object: `pymt__PaymentX__c` (LinvioPay)

### Key Fields for Transfer Logic
| Field API | Type | Usage |
|-----------|------|-------|
| `pymt__Amount__c` | Currency | Payment amount — must be updated to reflect transfer fee |
| `pymt__Status__c` | Picklist | Status: Scheduled, In Process, Completed, Cancelled |
| `pymt__Date__c` | Date | Payment date |
| `pymt__Opportunity__c` | Lookup(Opportunity) | Links payment to opportunity |
| `pymt__Contact__c` | Lookup(Contact) | Billing contact |
| `pymt__Account__c` | Lookup(Account) | Account |
| `Balance__c` | Custom | Balance remaining |
| `Amount_Due__c` | Custom | Amount due |
| `Attendee__c` | Custom Lookup | Links to Attendee record |
| `Billing_Contact__c` | Custom | Billing contact |
| `Registration_Status__c` | Custom | Registration status |
| `Opportunity_Stage__c` | Custom | Mirrors Opp stage |
| `Revise_Invoice__c` on Opportunity | Checkbox | Triggers invoice revision |

### Payment Query Pattern (from Cancel Flow)
**Not Paid path:** Query `pymt__PaymentX__c` WHERE `pymt__Opportunity__c = PaymentOpp` AND (`pymt__Status__c = 'Scheduled'` OR `pymt__Status__c = 'In Process'`), sorted by `pymt__Date__c DESC`.

**Paid path:** Query WHERE `pymt__Opportunity__c = PaymentOpp` AND `pymt__Status__c = 'Completed'`, sorted by `pymt__Date__c DESC`.

---

## 5. Transfer Subflow — Known Issues Mapped to Fixes

### Issue 1: Opportunity Stage
**Current flow sets:** `StageName = 'Closed Lost'`
**Should set:** `StageName = 'Transferred Out'`
**Cancel flow pattern:** Sets `StageName = 'Canceled'` (via assignment element `Set_Cancel_Reg_Opp_Closed_Lost_0`)

### Issue 2: Missing Credit Line Item
**Current flow:** DELETES original program fee OLI
**Should:** CREATE a negative OLI using **"Registration Fee Credit"** product (`REGCRED`, Id: `01t6T000006QSoCQAW`) with `UnitPrice = -(original program fee)`
**Cancel flow pattern:** Creates OLI with "Canceled" product where `UnitPrice = 0 - Opp.Amount`

### Issue 3: Payment Record Not Updated
**Current flow:** Does not update payment
**Should:** Update `pymt__Amount__c` on the payment record to the transfer fee amount
**Cancel flow pattern:**
  - Not Paid + No Fee: Update `pymt__Status__c = 'Cancelled'`
  - Not Paid + Fee: `NewPaymentAmount = Payment.Amount - Opp.Amount + Fee`
  
### Issue 4: Opportunity Additional Fields
Per cancel flow, also need to set:
- `Reg_Change_Date__c = TODAY()`
- `Reg_Change_Processed_By__c = $User.Id`
- `Registration_Change_Type__c = 'Transferred Out'`
- `Reg_Change_Comments__c` (from user input)
- `Revise_Invoice__c = true`
- If parent Opp exists: Also set `Revise_Invoice__c = true` on parent

---

## 6. LWC Component Design

### Architecture
```
transferRegistration/                    ← Parent wizard component
├── transferRegistration.html
├── transferRegistration.js
├── transferRegistration.css
├── transferRegistration.js-meta.xml     ← Exposed as Quick Action on evt__Attendee__c
│
├── (Child Components - optional, can be sections in parent)
│   ├── transferProgramSelector/         ← Step 1: Pick target program
│   ├── transferFeeReview/               ← Step 2: Fee breakdown & settlement
│   └── transferConfirmation/            ← Step 3: Confirm & execute
│
TransferRegistrationController.cls       ← Apex backend
TransferRegistrationControllerTest.cls   ← Test class
```

### Apex Controller Methods

```java
public with sharing class TransferRegistrationController {

    // 1. Load initial context
    @AuraEnabled(cacheable=true)
    public static TransferContext getTransferContext(Id attendeeId) {
        // Returns: Attendee, Opportunity, OLIs, Payment, Contact info
        // Includes: Payment status, Has_Parent_Opportunity, amounts
    }

    // 2. Search available programs to transfer to
    @AuraEnabled
    public static List<ProgramOption> getAvailablePrograms(String searchTerm, Id excludeEventId) {
        // Returns: evt__Special_Event__c records available for transfer
    }

    // 3. Calculate fee breakdown (real-time preview)
    @AuraEnabled
    public static FeeBreakdown calculateTransferFees(Id opportunityId, Id targetEventId, Decimal transferFeeAmount) {
        // Returns: original fee, credit amount, transfer fee, net owed
    }

    // 4. Execute the transfer (single transaction)
    @AuraEnabled
    public static TransferResult executeTransfer(TransferRequest request) {
        Savepoint sp = Database.setSavepoint();
        try {
            // a) Get Standard Price Book
            Pricebook2 stdPB = [SELECT Id FROM Pricebook2 WHERE Name = 'Standard Price Book' LIMIT 1];

            // b) Update Attendee: evt__Invitation_Status__c = 'Transferred'
            
            // c) Create Registration Fee Credit OLI (NEGATIVE)
            //    Product: "Registration Fee Credit" (01t6T000006QSoCQAW)
            //    UnitPrice: -(original program fee)
            
            // d) Create Transfer Fee OLI (POSITIVE) — if applicable
            //    Product: "Transfer Fee" (01t6T000005nbIdQAI)
            //    UnitPrice: transfer fee amount
            
            // e) Update Payment record
            //    - If Not Paid: pymt__Amount__c = transfer fee amount
            //    - If Paid: handle unapplied funds scenario
            
            // f) Update original Opportunity
            //    - StageName = 'Transferred Out'
            //    - Registration_Change_Type__c = 'Transferred Out'
            //    - Reg_Change_Date__c = Date.today()
            //    - Reg_Change_Processed_By__c = UserInfo.getUserId()
            //    - Reg_Change_Comments__c = comments
            //    - Revise_Invoice__c = true
            
            // g) If parent Opp: Update parent Revise_Invoice__c = true
            
            // h) Create new Opportunity for target program
            
            // i) Create OpportunityContactRole on new Opp
            
            return new TransferResult(true, newOpp.Id);
        } catch (Exception e) {
            Database.rollback(sp);
            return new TransferResult(false, e.getMessage());
        }
    }

    // Inner classes
    public class TransferContext { /* Attendee, Opp, OLIs, Payment, Contact */ }
    public class ProgramOption { /* Event Id, Name, Dates, Price */ }
    public class FeeBreakdown { /* originalFee, creditAmount, transferFee, netOwed */ }
    public class TransferRequest { /* attendeeId, targetEventId, transferFee, comments, settlementType */ }
    public class TransferResult { /* success, newOpportunityId, errorMessage */ }
}
```

### LWC Wizard Steps

**Step 1 — Select Program:**
- Display current registration summary (attendee, program, payment status)
- Searchable combobox for target program (evt__Special_Event__c)
- Program details preview on selection

**Step 2 — Review Fees & Settlement:**
- Financial summary table:
  ```
  Original Program Fee:           $9,950.00
  Registration Fee Credit:       -$9,950.00
  Transfer Fee:                     $500.00
  ──────────────────────────────────────────
  Net Amount Owed:                  $500.00
  ```
- If participant has PAID: Show settlement options (Refund / Unapplied Funds) — mirror Cancel flow
- If NOT PAID: Payment amount auto-adjusted
- Transfer comments textarea

**Step 3 — Confirm & Execute:**
- Summary of all changes that will be made
- "Confirm Transfer" button
- Spinner during processing
- On success: Toast + navigate to new Opportunity
- On error: Detailed message + rollback confirmation

---

## 7. Settlement Scenarios (from Cancel Flow Patterns)

| Payment Status | Has Parent Opp | Settlement Options | Actions |
|---------------|---------------|-------------------|---------|
| **Not Paid** | No | N/A — just adjust payment | Update `pymt__Amount__c` to transfer fee; or cancel payment if no transfer fee |
| **Not Paid** | Yes (Bundle) | N/A — adjust on parent payment | Recalculate parent payment amount |
| **Paid** | No | Refund / Unapplied Funds | Create Refund OLI + Task, OR create Unapplied Funds record |
| **Paid** | Yes (Bundle) | Refund / Unapplied Funds / Apply to Balance | Same as above + option to apply to remaining bundle balance |
| **Partial** | No | Refund / Unapplied Funds | Combination of paid/unpaid handling |
| **Partial** | Yes (Bundle) | Refund / Unapplied Funds / Apply to Balance | Full combination |

---

## 8. Implementation Phases

### Phase 1: Apex Controller (5-8 hours)
- `TransferRegistrationController.cls` with all methods
- Test class with scenarios: paid/unpaid, with/without fee, bundled/standalone
- All DML in single transaction with savepoint rollback

### Phase 2: LWC Component (8-12 hours)
- Parent wizard with lightning-progress-indicator
- Step 1: Program selector with search
- Step 2: Fee review with real-time calc + settlement options
- Step 3: Confirmation with execute
- Error handling, toasts, navigation

### Phase 3: Integration (3-5 hours)
- Quick Action on evt__Attendee__c record page
- Replace existing flow button with LWC action
- Test with Lauren's reference scenarios:
  - Already paid: `006Kh00000dijnSIAQ`
  - Unpaid: `0066T00001FNJ6SQAX`

### Phase 4: Polish & Edge Cases (3-5 hours)
- Aviation/Military participants (program not yet available)
- Unapplied funds flow
- Parent/bundled opportunity handling
- Permission checks

**Estimated Total: 19-30 hours**

---

## 9. Open Questions

1. ✅ ~~Credit Product~~ → **Registration Fee Credit** (`REGCRED`, negative UnitPrice)
2. ✅ ~~Payment Object~~ → **pymt__PaymentX__c** (LinvioPay), key fields: `pymt__Amount__c`, `pymt__Status__c`
3. ✅ ~~Cancel Flow Reference~~ → **Cancellations_Subflow** (fully analyzed above)
4. **New Opportunity Fields:** What fields copy from source to new Opp? (Need to check Transfer_Subflow's Create Records element)
5. **Quick Action placement:** Launch from Attendee record? Or keep in parent Cancellations/Transfers/Substitution flow but replace just the Transfer subflow?
6. **Email Notifications:** Any automated emails on transfer?
7. **Unapplied Funds for Transfer:** The "Transfer to Unapplied Funds" product is currently **inactive**. Should it be reactivated for transfer scenarios where the participant has already paid?
