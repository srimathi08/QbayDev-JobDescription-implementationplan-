import updateTasksOnClosedLost 
    from '@salesforce/apex/OpportunityTaskController.updateTasksOnClosedLost';
import { LightningElement, api, wire, track } from 'lwc';
import { getRecord, updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Apex
import closeRelatedTasks from '@salesforce/apex/OpportunityTaskController.closeRelatedTasks';

// Schema
import STAGE_NAME_FIELD from '@salesforce/schema/Opportunity.StageName';
import ON_HOLD_FIELD from '@salesforce/schema/Opportunity.Is_On_Hold__c';
import STAGE_REASON_FIELD from '@salesforce/schema/Opportunity.Stage_Change_Reason__c';
import HOLD_REASON_FIELD from '@salesforce/schema/Opportunity.Hold_Release_Reason__c';
import LOSS_REASON_FIELD from '@salesforce/schema/Opportunity.Loss_Reason__c';

const FIELDS = [
    'Opportunity.StageName',
    'Opportunity.RecordType.DeveloperName',
    'Opportunity.Is_On_Hold__c',
    'Opportunity.Hold_Release_Reason__c'
];

export default class OpportunityStagePath extends LightningElement {
    @api recordId;

    @track currentStage;
    @track recordType;
    @track isOnHold = false;
    @track stageItems = [];

    // Hold / Release
    @track isHoldAction = false;
    @track newHoldState = false;
    existingHoldReason = '';

    // Modal
    @track showModal = false;
    @track reasonText = '';
    newStage = '';

    /* -------------------- DATA LOAD -------------------- */

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredOpportunity({ data, error }) {
        if (data) {
            this.currentStage = data.fields.StageName.value;
            this.recordType = data.fields.RecordType.value.fields.DeveloperName.value;
            this.isOnHold = data.fields.Is_On_Hold__c.value;
            this.existingHoldReason = data.fields.Hold_Release_Reason__c?.value || '';

            this.initializePath();
        } else if (error) {
            console.error(error);
        }
    }

    /* -------------------- PATH SETUP -------------------- */

    initializePath() {
        let stages = [];

        switch (this.recordType) {
            case 'Project':
                stages = [
                    'Opportunity Identification & Qualification',
                    'Requirement Discovery & Scoping',
                    'Solutioning & Architecture Design',
                    'Effort Estimation & Resource Planning',
                    'Costing & Pricing',
                    'Proposal Development',
                    'Internal Review',
                    'Client Presentation',
                    'Negotiation',
                    'Contract Finalization',
                    'Closed Won',
                    'Closed Lost'
                ];
                break;

            case 'Resourcing':
                stages = [
                    'Discovery',
                    'Qualified',
                    'Resourcing',
                    'Internal Eval',
                    'Cust Eval',
                    'Negotiate',
                    'Awaiting',
                    'Signature',
                    'Closed Won',
                    'Closed Lost'
                ];
                break;

            case 'SW_Sales':
            case 'SW Sales':
                stages = [
                    'Discovery',
                    'Pre-Sales',
                    'Solution',
                    'Demo',
                    'Quote',
                    'Negotiate',
                    'Awaiting',
                    'Signature',
                    'Closed Won',
                    'Closed Lost'
                ];
                break;
        }

        // Hide Closed Lost once Closed Won
        if (this.currentStage === 'Closed Won') {
            stages = stages.filter(stage => stage !== 'Closed Lost');
        }

        this.stageItems = stages.map(label => ({ label }));
    }

    getStageIndex() {
        return this.stageItems.findIndex(
            s => s.label === this.currentStage
        );
    }

    get computedPath() {
        const activeIndex = this.getStageIndex();

        return this.stageItems.map((item, index) => {
            let sldsClass = 'slds-path__item slds-is-incomplete';
            let isHoldDisabled = false;

            if (index < activeIndex) {
                sldsClass = 'slds-path__item slds-is-complete';
            } else if (index === activeIndex) {
                sldsClass = 'slds-path__item slds-is-current slds-is-active';
            }

            if (this.isOnHold && index > activeIndex) {
                sldsClass += ' slds-path-paused';
                isHoldDisabled = true;
            }

            return { ...item, sldsClass, isHoldDisabled };
        });
    }

    /* -------------------- TASK COMPLETION (APEX) -------------------- */

    async completeOpportunityTasks() {
        try {
            const completedCount = await closeRelatedTasks({
                opportunityId: this.recordId
            });

            if (completedCount > 0) {
                this.showToast(
                    'Tasks Completed',
                    `${completedCount} related tasks were automatically completed.`,
                    'success'
                );
            }
        } catch (error) {
            console.error('Task completion failed', error);
            // silent by design
        }
    }

    /* -------------------- CLICK HANDLING -------------------- */

   handleStageClick(event) {
    const selectedStage = event.currentTarget.dataset.stage;
    const isDisabled = event.currentTarget.dataset.disabled === 'true';

    if (isDisabled || selectedStage === this.currentStage) {
        return;
    }

    // Find stage indexes
    const currentIndex = this.stageItems.findIndex(s => s.label === this.currentStage);
    const newIndex = this.stageItems.findIndex(s => s.label === selectedStage);

    // Show modal if moving backward OR moving to Closed Lost
    if (newIndex < currentIndex || selectedStage === 'Closed Lost') {
        this.newStage = selectedStage;
        this.isHoldAction = false;
        this.showModal = true; // open modal
        return;
    }

    // Forward move → no modal
    this.updateStage(selectedStage, null);
}



    handleReasonChange(event) {
        this.reasonText = event.target.value;
    }

    closeModal() {
        this.showModal = false;
        this.reasonText = '';
        this.newStage = '';
        this.isHoldAction = false;
    }

    async handleClosedLostTasks(lossReason) {
    try {
        const updatedCount = await updateTasksOnClosedLost({
            opportunityId: this.recordId,
            lossReason: lossReason
        });

        if (updatedCount > 0) {
            this.showToast(
                'Tasks Updated',
                `${updatedCount} related tasks updated with loss reason.`,
                'success'
            );
        }
    } catch (error) {
        console.error('Closed Lost task update failed', error);
        // silent failure by design
    }
}


    /* -------------------- SUBMIT -------------------- */

    submitReason() {
        if (!this.reasonText?.trim()) {
            this.showToast(
                'Validation Error',
                'Please enter a valid reason.',
                'error'
            );
            return;
        }

        if (this.isHoldAction) {
            this.saveHoldReason();
            return;
        }

        if (this.newStage === 'Closed Lost') {
            this.updateClosedLost(this.reasonText);
            this.closeModal();
            return;
        }

        this.updateStage(this.newStage, this.reasonText);
        this.closeModal();
    }

    /* -------------------- HOLD / RELEASE -------------------- */

    handleHoldToggle() {
        this.isHoldAction = true;
        this.newHoldState = !this.isOnHold;
        this.showModal = true;
    }

    saveHoldReason() {
        const fields = {};
        fields.Id = this.recordId;
        fields[ON_HOLD_FIELD.fieldApiName] = this.newHoldState;

        const actionLabel = this.newHoldState ? 'Hold' : 'Release';
        const newEntry = `${this.currentStage} (${actionLabel}) - ${this.reasonText}`;

        fields[HOLD_REASON_FIELD.fieldApiName] =
            this.existingHoldReason
                ? this.existingHoldReason + '\n' + newEntry
                : newEntry;

        updateRecord({ fields })
            .then(() => {
                this.isOnHold = this.newHoldState;
                this.existingHoldReason = fields[HOLD_REASON_FIELD.fieldApiName];

                this.showToast(
                    'Status Updated',
                    this.newHoldState ? 'Opportunity is now On Hold.' : 'Opportunity resumed.',
                    this.newHoldState ? 'warning' : 'success'
                );

                this.closeModal();
            })
            .catch(() => {
                this.showToast('Error', 'Failed to update Hold status.', 'error');
            });
    }

    /* -------------------- CLOSED LOST -------------------- */

   updateClosedLost(lossReason) {
    const fields = {};
    fields.Id = this.recordId;
    fields[STAGE_NAME_FIELD.fieldApiName] = 'Closed Lost';
    fields[LOSS_REASON_FIELD.fieldApiName] = lossReason;

    updateRecord({ fields })
        .then(async () => {

            // 🔥 NEW: Update related tasks
            await this.handleClosedLostTasks(lossReason);

            this.showToast(
                'Stage Updated',
                'Opportunity marked as Closed Lost.',
                'success'
            );
        })
        .catch(error => {
            this.showToast(
                'Error',
                error.body?.message || 'Update failed',
                'error'
            );
        });
}

    /* -------------------- GENERIC STAGE UPDATE -------------------- */

    updateStage(newStage, reason) {
        const fields = {};
        fields.Id = this.recordId;
        fields[STAGE_NAME_FIELD.fieldApiName] = newStage;

        if (reason) {
            fields[STAGE_REASON_FIELD.fieldApiName] = reason;
        }

        updateRecord({ fields })
            .then(async () => {
                if (newStage === 'Closed Won') {
                    await this.completeOpportunityTasks();
                }

                this.showToast(
                    'Stage Updated',
                    `Stage changed to ${newStage}`,
                    'success'
                );
            })
            .catch(error => {
                this.showToast(
                    'Error',
                    error.body?.message,
                    'error'
                );
            });
    }

    /* -------------------- UI HELPERS -------------------- */

    get holdButtonLabel() {
        return this.isOnHold ? 'Release Hold' : 'Put On Hold';
    }

    get holdButtonVariant() {
        return this.isOnHold ? 'success' : 'destructive';
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant })
        );
    }
}