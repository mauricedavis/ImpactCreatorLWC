import { LightningElement, api, track, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import getInitData from '@salesforce/apex/ImpactCreatorController.getInitData';
import createImpact from '@salesforce/apex/ImpactCreatorController.createImpact';
import searchUsers from '@salesforce/apex/ImpactCreatorController.searchUsers';
import searchAccounts from '@salesforce/apex/ImpactCreatorController.searchAccounts';

const STEPS = [
    { label: 'Impact Details', value: 'details', icon: 'standard:opportunity' },
    { label: 'Capital Sources', value: 'sources', icon: 'standard:product' },
    { label: 'Impact Team', value: 'team', icon: 'standard:team_member' },
    { label: 'Review & Create', value: 'review', icon: 'standard:task2' }
];

export default class ImpactCreator extends NavigationMixin(LightningElement) {
    @api recordId; // Case Id passed from quick action

    // ── State ──────────────────────────────────────────────────────
    isLoading = true;
    isSaving = false;
    currentStep = 'details';
    steps = STEPS;

    // Init data from Apex
    caseRecord;
    caseOwnerName;
    accountName;
    accountStartDate;
    accountInBusiness;
    allCapitalSources = [];
    stageOptions = [];
    salesSourceOptions = [];
    teamRoleOptions = [];
    partnerTypeOptions = [];
    capitalSourceTypeOptions = [];

    // Step 1: Impact Details
    impactName = '';
    attributionDate;
    stageName = '';
    salesIncrease = null;
    salesSource = '';
    jobsCreated = null;
    jobsRetained = null;
    newBusiness = false;
    boughtBusiness = false;
    soldBusiness = false;
    overrideStartDate = null;

    // Step 2: Capital Sources
    capitalSourceSearch = '';
    @track selectedSourceIds = new Set();
    @track capitalSourceLines = []; // configured lines with amounts

    // Step 3: Team Members
    @track teamMembers = [];
    userSearchTerm = '';
    userSearchResults = [];
    showUserDropdown = false;

    // Step 4: Result
    createdOpportunityId;
    createdOpportunityName;
    createdOliCount;
    createdTeamMemberCount;
    isCreated = false;

    // ── Lifecycle ──────────────────────────────────────────────────

    connectedCallback() {
        this.attributionDate = new Date().toISOString().split('T')[0];
    }

    @wire(getInitData, { caseId: '$recordId' })
    wiredInit({ error, data }) {
        if (data) {
            this.caseRecord = data.caseRecord;
            this.caseOwnerName = data.caseOwnerName;
            this.accountName = data.accountName;
            this.accountStartDate = data.accountStartDate;
            this.accountInBusiness = data.accountInBusiness;
            this.allCapitalSources = data.capitalSources || [];
            this.stageOptions = (data.stageOptions || []).map(o => ({ label: o.label, value: o.value }));
            this.salesSourceOptions = [
                { label: '--None--', value: '' },
                ...(data.salesSourceOptions || []).map(o => ({ label: o.label, value: o.value }))
            ];
            this.teamRoleOptions = (data.teamRoleOptions || []).map(o => ({ label: o.label, value: o.value }));
            this.partnerTypeOptions = [
                { label: '--None--', value: '' },
                ...(data.partnerTypeOptions || []).map(o => ({ label: o.label, value: o.value }))
            ];
            this.capitalSourceTypeOptions = [
                { label: '--None--', value: '' },
                ...(data.capitalSourceTypeOptions || []).map(o => ({ label: o.label, value: o.value }))
            ];

            // Auto-add Case Owner as first team member
            if (this.caseRecord && this.caseRecord.OwnerId) {
                this.teamMembers = [{
                    id: this._uid(),
                    userId: this.caseRecord.OwnerId,
                    userName: this.caseOwnerName,
                    role: 'Lead Consultant',
                    capitalFormation: null,
                    jobsCreated: null,
                    jobsRetained: null,
                    salesIncrease: null,
                    isFirst: true
                }];
            }
            this.isLoading = false;
        } else if (error) {
            this._showToast('Error', this._reduceErrors(error), 'error');
            this.isLoading = false;
        }
    }

    // ── Step Navigation ────────────────────────────────────────────

    get isDetailsStep()  { return this.currentStep === 'details'; }
    get isSourcesStep()  { return this.currentStep === 'sources'; }
    get isTeamStep()     { return this.currentStep === 'team'; }
    get isReviewStep()   { return this.currentStep === 'review'; }

    get isPrevDisabled() { return this.currentStep === 'details' || this.isCreated; }
    get isNextHidden()   { return this.currentStep === 'review'; }
    get isSubmitHidden() { return this.currentStep !== 'review' || this.isCreated; }

    get currentStepIndex() {
        return STEPS.findIndex(s => s.value === this.currentStep);
    }

    get computedSteps() {
        const idx = this.currentStepIndex;
        return STEPS.map((step, i) => {
            let dotClass = 'step-path-dot';
            let labelClass = 'step-path-label';
            let itemClass = 'step-path-item';
            if (i < idx) {
                dotClass += ' step-complete';
                labelClass += ' step-label-complete';
            } else if (i === idx) {
                dotClass += ' step-active';
                labelClass += ' step-label-active';
                itemClass += ' step-item-active';
            }
            return { ...step, dotClass, labelClass, itemClass };
        });
    }

    handleStepClick(event) {
        const target = event.currentTarget.dataset.step;
        if (this.isCreated) return;
        // Allow clicking on previous steps, validate if going forward
        const targetIdx = STEPS.findIndex(s => s.value === target);
        if (targetIdx <= this.currentStepIndex) {
            this.currentStep = target;
        }
    }

    handleNext() {
        if (!this._validateCurrentStep()) return;
        const idx = this.currentStepIndex;
        if (idx < STEPS.length - 1) {
            this.currentStep = STEPS[idx + 1].value;
        }
    }

    handlePrev() {
        const idx = this.currentStepIndex;
        if (idx > 0) {
            this.currentStep = STEPS[idx - 1].value;
        }
    }

    // ── Step 1: Impact Details ─────────────────────────────────────

    handleFieldChange(event) {
        const field = event.target.dataset.field;
        if (!field) return;
        const type = event.target.type;
        if (type === 'checkbox' || type === 'toggle') {
            this[field] = event.target.checked;
        } else {
            this[field] = event.target.value;
        }
    }

    get showStartDateWarning() {
        const hasDate = this.accountStartDate != null;
        const inBiz = this.accountInBusiness === true;
        return (hasDate && !inBiz) || (!hasDate && inBiz);
    }

    get formattedAccountStartDate() {
        if (!this.accountStartDate) return 'Not set';
        return this.accountStartDate;
    }

    get formattedInBusiness() {
        if (this.accountInBusiness == null) return 'Not set';
        return this.accountInBusiness ? 'Yes' : 'No';
    }

    // ── Step 2: Capital Sources ────────────────────────────────────

    get filteredCapitalSources() {
        const term = (this.capitalSourceSearch || '').toLowerCase();
        return this.allCapitalSources.filter(cs => {
            if (!term) return true;
            return (cs.Name || '').toLowerCase().includes(term) ||
                   (cs.Family || '').toLowerCase().includes(term) ||
                   (cs.Sub_Type__c || '').toLowerCase().includes(term) ||
                   (cs.Description || '').toLowerCase().includes(term);
        });
    }

    get hasCapitalSources() { return this.filteredCapitalSources.length > 0; }

    get capitalSourcesForDisplay() {
        return this.filteredCapitalSources.map(cs => ({
            ...cs,
            isSelected: this.selectedSourceIds.has(cs.Id),
            rowClass: this.selectedSourceIds.has(cs.Id)
                ? 'slds-hint-parent row-selected'
                : 'slds-hint-parent'
        }));
    }

    get selectedSourceCount() { return this.selectedSourceIds.size; }
    get hasSelectedSources() { return this.selectedSourceIds.size > 0; }

    handleSourceSearch(event) {
        this.capitalSourceSearch = event.target.value;
    }

    handleToggleSource(event) {
        const prodId = event.currentTarget.dataset.id;
        const updated = new Set(this.selectedSourceIds);
        if (updated.has(prodId)) {
            updated.delete(prodId);
            // Remove from lines too
            this.capitalSourceLines = this.capitalSourceLines.filter(l => l.productId !== prodId);
        } else {
            updated.add(prodId);
            // Add a new line with defaults
            const product = this.allCapitalSources.find(cs => cs.Id === prodId);
            this.capitalSourceLines = [
                ...this.capitalSourceLines,
                {
                    id: this._uid(),
                    productId: prodId,
                    productName: product.Name,
                    partnerType: product.Partner_Type__c || '',
                    amount: null,
                    serviceDate: new Date().toISOString().split('T')[0],
                    capitalSourceType: product.Partner_Type__c || '',
                    capitalSourcePartnerId: '',
                    capitalSourcePartnerName: '',
                    quantity: 1,
                    // Account search state per line
                    accountSearchTerm: '',
                    accountSearchResults: [],
                    showAccountDropdown: false
                }
            ];
        }
        this.selectedSourceIds = updated;
    }

    handleSelectAll() {
        const visible = this.filteredCapitalSources;
        const allSelected = visible.every(cs => this.selectedSourceIds.has(cs.Id));
        const updated = new Set(this.selectedSourceIds);

        if (allSelected) {
            // Deselect all visible
            visible.forEach(cs => {
                updated.delete(cs.Id);
                this.capitalSourceLines = this.capitalSourceLines.filter(l => l.productId !== cs.Id);
            });
        } else {
            // Select all visible
            visible.forEach(cs => {
                if (!updated.has(cs.Id)) {
                    updated.add(cs.Id);
                    this.capitalSourceLines = [
                        ...this.capitalSourceLines,
                        {
                            id: this._uid(),
                            productId: cs.Id,
                            productName: cs.Name,
                            partnerType: cs.Partner_Type__c || '',
                            amount: null,
                            serviceDate: new Date().toISOString().split('T')[0],
                            capitalSourceType: cs.Partner_Type__c || '',
                            capitalSourcePartnerId: '',
                            capitalSourcePartnerName: '',
                            quantity: 1,
                            accountSearchTerm: '',
                            accountSearchResults: [],
                            showAccountDropdown: false
                        }
                    ];
                }
            });
        }
        this.selectedSourceIds = updated;
    }

    get isAllSelected() {
        const visible = this.filteredCapitalSources;
        return visible.length > 0 && visible.every(cs => this.selectedSourceIds.has(cs.Id));
    }

    // Capital Source Line editing
    handleLineFieldChange(event) {
        const lineId = event.target.dataset.lineId;
        const field = event.target.dataset.field;
        const value = event.target.value;
        this.capitalSourceLines = this.capitalSourceLines.map(l => {
            if (l.id === lineId) {
                return { ...l, [field]: value };
            }
            return l;
        });
    }

    handleRemoveLine(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const line = this.capitalSourceLines.find(l => l.id === lineId);
        if (line) {
            const updated = new Set(this.selectedSourceIds);
            updated.delete(line.productId);
            this.selectedSourceIds = updated;
            this.capitalSourceLines = this.capitalSourceLines.filter(l => l.id !== lineId);
        }
    }

    // Capital Source Partner (Account) search per line
    handleAccountSearch(event) {
        const lineId = event.target.dataset.lineId;
        const term = event.target.value;
        this.capitalSourceLines = this.capitalSourceLines.map(l => {
            if (l.id === lineId) {
                return { ...l, accountSearchTerm: term };
            }
            return l;
        });
        if (term.length >= 2) {
            this._searchAccountsDebounced(lineId, term);
        } else {
            this.capitalSourceLines = this.capitalSourceLines.map(l => {
                if (l.id === lineId) {
                    return { ...l, accountSearchResults: [], showAccountDropdown: false };
                }
                return l;
            });
        }
    }

    _accountSearchTimeout;
    _searchAccountsDebounced(lineId, term) {
        clearTimeout(this._accountSearchTimeout);
        this._accountSearchTimeout = setTimeout(() => {
            searchAccounts({ searchTerm: term })
                .then(results => {
                    this.capitalSourceLines = this.capitalSourceLines.map(l => {
                        if (l.id === lineId) {
                            return {
                                ...l,
                                accountSearchResults: results,
                                showAccountDropdown: results.length > 0
                            };
                        }
                        return l;
                    });
                })
                .catch(err => {
                    console.error('Account search error:', err);
                });
        }, 300);
    }

    handleSelectAccount(event) {
        const lineId = event.currentTarget.dataset.lineId;
        const accountId = event.currentTarget.dataset.accountId;
        const accountName = event.currentTarget.dataset.accountName;
        this.capitalSourceLines = this.capitalSourceLines.map(l => {
            if (l.id === lineId) {
                return {
                    ...l,
                    capitalSourcePartnerId: accountId,
                    capitalSourcePartnerName: accountName,
                    accountSearchTerm: '',
                    accountSearchResults: [],
                    showAccountDropdown: false
                };
            }
            return l;
        });
    }

    handleClearAccount(event) {
        const lineId = event.currentTarget.dataset.lineId;
        this.capitalSourceLines = this.capitalSourceLines.map(l => {
            if (l.id === lineId) {
                return {
                    ...l,
                    capitalSourcePartnerId: '',
                    capitalSourcePartnerName: '',
                    accountSearchTerm: '',
                    accountSearchResults: [],
                    showAccountDropdown: false
                };
            }
            return l;
        });
    }

    handleAccountSearchBlur(event) {
        const lineId = event.target.dataset.lineId;
        setTimeout(() => {
            this.capitalSourceLines = this.capitalSourceLines.map(l => {
                if (l.id === lineId) {
                    return { ...l, showAccountDropdown: false };
                }
                return l;
            });
        }, 250);
    }

    get totalCapitalAmount() {
        return this.capitalSourceLines.reduce((sum, l) => {
            return sum + (parseFloat(l.amount) || 0);
        }, 0);
    }

    get formattedTotalCapitalAmount() {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
            .format(this.totalCapitalAmount);
    }

    get capitalDifference() {
        const impactTotal = parseFloat(this.salesIncrease) || 0;
        return impactTotal - this.totalCapitalAmount;
    }

    get formattedCapitalDifference() {
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
            .format(this.capitalDifference);
    }

    get capitalDifferenceChipClass() {
        const diff = this.capitalDifference;
        if (Math.abs(diff) < 0.01) return 'total-chip total-chip-match';
        return 'total-chip total-chip-mismatch';
    }

    // ── Step 3: Team Members ───────────────────────────────────────

    handleUserSearch(event) {
        this.userSearchTerm = event.target.value;
        if (this.userSearchTerm.length >= 2) {
            this._searchUsersDebounced();
        } else {
            this.userSearchResults = [];
            this.showUserDropdown = false;
        }
    }

    _searchTimeout;
    _searchUsersDebounced() {
        clearTimeout(this._searchTimeout);
        this._searchTimeout = setTimeout(() => {
            searchUsers({ searchTerm: this.userSearchTerm })
                .then(results => {
                    // Filter out users already on the team
                    const existingIds = new Set(this.teamMembers.map(tm => tm.userId));
                    this.userSearchResults = results.filter(u => !existingIds.has(u.userId));
                    this.showUserDropdown = this.userSearchResults.length > 0;
                })
                .catch(err => {
                    console.error('User search error:', err);
                    this.showUserDropdown = false;
                });
        }, 300);
    }

    handleSelectUser(event) {
        const userId = event.currentTarget.dataset.userId;
        const user = this.userSearchResults.find(u => u.userId === userId);
        if (user) {
            this.teamMembers = [
                ...this.teamMembers,
                {
                    id: this._uid(),
                    userId: user.userId,
                    userName: user.name,
                    role: 'Consultant',
                    capitalFormation: null,
                    jobsCreated: null,
                    jobsRetained: null,
                    salesIncrease: null,
                    isFirst: false
                }
            ];
        }
        this.userSearchTerm = '';
        this.userSearchResults = [];
        this.showUserDropdown = false;
    }

    handleUserSearchBlur() {
        // Delay to allow click on dropdown item
        setTimeout(() => {
            this.showUserDropdown = false;
        }, 250);
    }

    handleTeamFieldChange(event) {
        const memberId = event.target.dataset.memberId;
        const field = event.target.dataset.field;
        let value = event.target.value;
        this.teamMembers = this.teamMembers.map(tm => {
            if (tm.id === memberId) {
                return { ...tm, [field]: value };
            }
            return tm;
        });
    }

    handleRemoveTeamMember(event) {
        const memberId = event.currentTarget.dataset.memberId;
        this.teamMembers = this.teamMembers.filter(tm => tm.id !== memberId);
    }

    // Split totals
    get teamJobsCreatedTotal() {
        return this.teamMembers.reduce((s, tm) => s + (parseInt(tm.jobsCreated) || 0), 0);
    }
    get teamJobsRetainedTotal() {
        return this.teamMembers.reduce((s, tm) => s + (parseInt(tm.jobsRetained) || 0), 0);
    }
    get teamSalesIncreaseTotal() {
        return this.teamMembers.reduce((s, tm) => s + (parseFloat(tm.salesIncrease) || 0), 0);
    }
    get teamCapitalFormationTotal() {
        return this.teamMembers.reduce((s, tm) => s + (parseFloat(tm.capitalFormation) || 0), 0);
    }

    // Split validation
    get jobsCreatedSplitOk() {
        if (!this.jobsCreated) return true;
        return this.teamJobsCreatedTotal === parseInt(this.jobsCreated);
    }
    get jobsRetainedSplitOk() {
        if (!this.jobsRetained) return true;
        return this.teamJobsRetainedTotal === parseInt(this.jobsRetained);
    }
    get salesIncreaseSplitOk() {
        if (!this.salesIncrease) return true;
        return Math.abs(this.teamSalesIncreaseTotal - parseFloat(this.salesIncrease)) < 0.01;
    }
    get capitalFormationSplitOk() {
        if (this.totalCapitalAmount === 0) return true;
        return Math.abs(this.teamCapitalFormationTotal - this.totalCapitalAmount) < 0.01;
    }

    get allSplitsValid() {
        return this.jobsCreatedSplitOk && this.jobsRetainedSplitOk &&
               this.salesIncreaseSplitOk && this.capitalFormationSplitOk;
    }

    get jobsCreatedSplitClass() {
        return this.jobsCreatedSplitOk ? 'split-ok' : 'split-mismatch';
    }
    get jobsRetainedSplitClass() {
        return this.jobsRetainedSplitOk ? 'split-ok' : 'split-mismatch';
    }
    get salesIncreaseSplitClass() {
        return this.salesIncreaseSplitOk ? 'split-ok' : 'split-mismatch';
    }
    get capitalFormationSplitClass() {
        return this.capitalFormationSplitOk ? 'split-ok' : 'split-mismatch';
    }

    // Auto-distribute splits equally
    handleDistributeEvenly() {
        const count = this.teamMembers.length;
        if (count === 0) return;

        const jc = parseInt(this.jobsCreated) || 0;
        const jr = parseInt(this.jobsRetained) || 0;
        const si = parseFloat(this.salesIncrease) || 0;
        const cf = this.totalCapitalAmount;

        this.teamMembers = this.teamMembers.map((tm, idx) => {
            const isLast = idx === count - 1;
            const baseJC = Math.floor(jc / count);
            const baseJR = Math.floor(jr / count);
            const baseSI = Math.round((si / count) * 100) / 100;
            const baseCF = Math.round((cf / count) * 100) / 100;
            return {
                ...tm,
                jobsCreated: isLast ? jc - baseJC * (count - 1) : baseJC,
                jobsRetained: isLast ? jr - baseJR * (count - 1) : baseJR,
                salesIncrease: isLast
                    ? Math.round((si - baseSI * (count - 1)) * 100) / 100
                    : baseSI,
                capitalFormation: isLast
                    ? Math.round((cf - baseCF * (count - 1)) * 100) / 100
                    : baseCF
            };
        });
    }

    // Give 100% to a single team member
    handleAssignAll(event) {
        const memberId = event.currentTarget.dataset.memberId;
        this.teamMembers = this.teamMembers.map(tm => {
            if (tm.id === memberId) {
                return {
                    ...tm,
                    jobsCreated: parseInt(this.jobsCreated) || 0,
                    jobsRetained: parseInt(this.jobsRetained) || 0,
                    salesIncrease: parseFloat(this.salesIncrease) || 0,
                    capitalFormation: this.totalCapitalAmount
                };
            }
            return { ...tm, jobsCreated: 0, jobsRetained: 0, salesIncrease: 0, capitalFormation: 0 };
        });
    }

    // ── Step 4: Review ─────────────────────────────────────────────

    get reviewImpactDetails() {
        return {
            impactName: this.impactName,
            attributionDate: this.attributionDate,
            stage: this.stageName,
            salesIncrease: this.salesIncrease,
            salesSource: this.salesSource,
            jobsCreated: this.jobsCreated,
            jobsRetained: this.jobsRetained,
            newBusiness: this.newBusiness,
            boughtBusiness: this.boughtBusiness,
            soldBusiness: this.soldBusiness,
            accountName: this.accountName,
            caseNumber: this.caseRecord?.CaseNumber,
            leadConsultant: this.caseOwnerName
        };
    }

    get formattedSalesIncrease() {
        if (!this.salesIncrease) return '$0.00';
        return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD' })
            .format(this.salesIncrease);
    }

    // ── Submit ─────────────────────────────────────────────────────

    handleSubmit() {
        if (!this._validateAllSteps()) return;

        this.isSaving = true;
        const payload = {
            caseId: this.recordId,
            impactName: this.impactName,
            attributionDate: this.attributionDate,
            stageName: this.stageName,
            salesIncrease: parseFloat(this.salesIncrease) || null,
            salesSource: this.salesSource || null,
            jobsCreated: parseInt(this.jobsCreated) || null,
            jobsRetained: parseInt(this.jobsRetained) || null,
            newBusiness: this.newBusiness,
            boughtBusiness: this.boughtBusiness,
            soldBusiness: this.soldBusiness,
            businessStartDate: this.overrideStartDate || null,
            capitalSourceLines: this.capitalSourceLines.map(l => ({
                productId: l.productId,
                productName: l.productName,
                amount: this._toNum(l.amount),
                serviceDate: l.serviceDate,
                capitalSourceType: l.capitalSourceType || null,
                capitalSourcePartnerId: l.capitalSourcePartnerId || null,
                quantity: this._toNum(l.quantity) || 1
            })),
            teamMembers: this.teamMembers.map(tm => {
                const cf = this._toNum(tm.capitalFormation);
                const jc = this._toInt(tm.jobsCreated);
                const jr = this._toInt(tm.jobsRetained);
                const si = this._toNum(tm.salesIncrease);
                console.log(`Team member ${tm.userName}: CF=${cf}, JC=${jc}, JR=${jr}, SI=${si}, raw SI=${tm.salesIncrease}, type=${typeof tm.salesIncrease}`);
                return {
                    userId: tm.userId,
                    userName: tm.userName,
                    role: tm.role,
                    capitalFormation: cf,
                    jobsCreated: jc,
                    jobsRetained: jr,
                    salesIncrease: si
                };
            })
        };

        createImpact({ payloadJson: JSON.stringify(payload) })
            .then(result => {
                this.createdOpportunityId = result.opportunityId;
                this.createdOpportunityName = result.opportunityName;
                this.createdOliCount = result.oliCount;
                this.createdTeamMemberCount = result.teamMemberCount;
                this.isCreated = true;
                this._showToast(
                    'Impact Created',
                    `"${result.opportunityName}" created with ${result.oliCount} Capital Source(s) and ${result.teamMemberCount} Team Member(s).`,
                    'success'
                );
            })
            .catch(error => {
                this._showToast('Error Creating Impact', this._reduceErrors(error), 'error');
            })
            .finally(() => {
                this.isSaving = false;
            });
    }

    handleViewImpact() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: this.createdOpportunityId,
                objectApiName: 'Opportunity',
                actionName: 'view'
            }
        });
    }

    handleClose() {
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // ── Validation ─────────────────────────────────────────────────

    _validateCurrentStep() {
        switch (this.currentStep) {
            case 'details': return this._validateDetails();
            case 'sources': return true; // Sources are optional
            case 'team': return this._validateTeam();
            default: return true;
        }
    }

    _validateDetails() {
        const inputs = this.template.querySelectorAll('[data-validate="details"]');
        let valid = true;
        inputs.forEach(input => {
            if (!input.reportValidity()) valid = false;
        });
        if (!this.impactName) {
            this._showToast('Validation', 'Impact Name is required.', 'warning');
            valid = false;
        }
        if (!this.stageName) {
            this._showToast('Validation', 'Stage is required.', 'warning');
            valid = false;
        }
        return valid;
    }

    _validateTeam() {
        if (this.teamMembers.length === 0) {
            this._showToast('Validation', 'At least one team member is required.', 'warning');
            return false;
        }
        // Check all team members have a role
        for (const tm of this.teamMembers) {
            if (!tm.role) {
                this._showToast('Validation', `Please select a role for ${tm.userName}.`, 'warning');
                return false;
            }
        }
        return true;
    }

    _validateAllSteps() {
        if (!this._validateDetails()) {
            this.currentStep = 'details';
            return false;
        }
        if (!this._validateTeam()) {
            this.currentStep = 'team';
            return false;
        }
        // Warn (not block) on split mismatch
        if (!this.allSplitsValid) {
            this._showToast(
                'Split Mismatch Warning',
                'Team member value splits do not match Impact totals. Please verify before proceeding.',
                'warning'
            );
            // Still allow submit — it's a warning
        }
        return true;
    }

    // ── Helpers ────────────────────────────────────────────────────

    _uid() {
        return 'uid-' + Math.random().toString(36).substr(2, 9) + Date.now();
    }

    /** Safely parse a number that may be currency-formatted (e.g. "$1,234.56") */
    _toNum(val) {
        if (val == null || val === '') return 0;
        if (typeof val === 'number') return val;
        // Strip $, commas, spaces
        const cleaned = String(val).replace(/[$,\s]/g, '');
        const num = parseFloat(cleaned);
        return isNaN(num) ? 0 : num;
    }

    /** Safely parse an integer that may have formatting */
    _toInt(val) {
        if (val == null || val === '') return 0;
        if (typeof val === 'number') return Math.round(val);
        const cleaned = String(val).replace(/[$,\s]/g, '');
        const num = parseInt(cleaned, 10);
        return isNaN(num) ? 0 : num;
    }

    _showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    _reduceErrors(error) {
        if (typeof error === 'string') return error;
        if (error?.body?.message) return error.body.message;
        if (error?.message) return error.message;
        if (Array.isArray(error?.body)) return error.body.map(e => e.message).join(', ');
        return 'Unknown error';
    }
}
