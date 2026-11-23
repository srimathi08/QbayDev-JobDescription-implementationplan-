/*import { LightningElement, api, wire, track } from 'lwc';
import getCountsForOpportunity from '@salesforce/apex/OpportunityFlexSummaryController.getCountsForOpportunity';

export default class OpportunityFlexCard extends LightningElement {
    @api recordId;
    @track summary;
    @track error;

    @wire(getCountsForOpportunity, { opportunityId: '$recordId' })
    wiredSummary({ data, error }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body.message;
            this.summary = undefined;
        }
    }
}*/


import { LightningElement, api, wire, track } from 'lwc';
import getCountsForOpportunity from '@salesforce/apex/OpportunityFlexSummaryController.getCountsForOpportunity';
import getEligibleCandidates from '@salesforce/apex/OpportunityFlexSummaryController.getEligibleCandidates';
import getPresentedCandidates from '@salesforce/apex/OpportunityFlexSummaryController.getPresentedCandidates';
import getInterviewRecords from '@salesforce/apex/OpportunityFlexSummaryController.getInterviewRecords';
import deleteJobMatchRecord from '@salesforce/apex/OpportunityFlexSummaryController.deleteJobMatchRecord';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class OpportunityFlexCard extends LightningElement {
    @api recordId;
    @track summary;
    @track error;

    @track showModal = false;
    @track modalTitle = '';
    @track modalData = [];
    @track columns = [];

    @wire(getCountsForOpportunity, { opportunityId: '$recordId' })
    wiredSummary({ data, error }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.error = error.body.message;
            this.summary = undefined;
        }
    }
 // 🔹 Eligible Candidates
    handleClickEligible() {
        this.modalTitle = 'Eligible Candidates';
        getEligibleCandidates({ opportunityId: this.recordId })
            .then(result => {
                this.modalData = result.map(row => ({
                    Id: row.Id,
                    CandidateName: row.Candidate_Name__r?.Name,
                    CandidateUrl: '/' + row.Candidate_Name__r?.Id,
                    OpportunityName: row.Opportunity_Name__r?.Name,
                    //MatchScore: row.Match_Score__c
                    MatchScore: row.Match_Score__c != null ? row.Match_Score__c.toString() : ''
                }));

                /*this.columns = [
                    {
                        label: 'Candidate Name',
                        fieldName: 'CandidateUrl',
                        type: 'url',
                        typeAttributes: {
                            label: { fieldName: 'CandidateName' },
                            target: '_blank'
                        }
                    },
                    { label: 'Opportunity', fieldName: 'OpportunityName' },
                    { label: 'Match Score', fieldName: 'MatchScore', type: 'number' }
                ];*/

this.columns = [
    {
        label: 'Candidate Name',
        fieldName: 'CandidateUrl',
        type: 'url',
        typeAttributes: {
            label: { fieldName: 'CandidateName' },
            target: '_blank'
        }
    },
    { label: 'Opportunity', fieldName: 'OpportunityName' },
    { 
        label: 'Match Score', 
        fieldName: 'MatchScore', 
        type: 'text', // <- note: 'text'
        cellAttributes: { alignment: 'center' }
    },
                    {
                        type: 'button-icon',
                        fixedWidth: 50,
                        typeAttributes: {
                            iconName: 'utility:close',
                            alternativeText: 'Remove',
                            title: 'Remove Candidate',
                            variant: 'bare',
                            name: 'remove'
                        }
                    }
];



                this.showModal = true;
            })
            .catch(error => {
                this.error = error.body.message;
            });
    }

handleRowAction(event) {
    const actionName = event.detail.action.name;
    const row = event.detail.row;

    if (actionName === 'remove') {
        deleteJobMatchRecord({ recordId: row.Id })
            .then(() => {
                this.modalData = this.modalData.filter(item => item.Id !== row.Id);

                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Success',
                        message: 'Candidate removed successfully.',
                        variant: 'success'
                    })
                );
            })
            .catch(error => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Error removing candidate',
                        message: error.body.message,
                        variant: 'error'
                    })
                );
            });
    }
}


    // 🔹 Interviews Scheduled
    handleClickInterview() {
        this.modalTitle = 'Interviews Scheduled';
        getInterviewRecords({ opportunityId: this.recordId })
            .then(result => {
                this.modalData = result.map(row => ({
                    Id: row.Id,
                    CandidateName: row.Candidate_Name__r?.Name,
                    CandidateUrl: '/' + row.Candidate_Name__r?.Id,
                    OpportunityName: row.Opportunity__r?.Name,
                    InterviewStage: row.Interview_Stage__c,
                    InterviewerName: row.Interviewer_Name__r?.Name
                }));

                this.columns = [
                    {
                        label: 'Candidate Name',
                        fieldName: 'CandidateUrl',
                        type: 'url',
                        typeAttributes: {
                            label: { fieldName: 'CandidateName' },
                            target: '_blank'
                        }
                    },
                    { label: 'Opportunity', fieldName: 'OpportunityName' },
                    { label: 'Interview Stage', fieldName: 'InterviewStage' },
                    { label: 'Interviewer Name', fieldName: 'InterviewerName' }
                ];

                this.showModal = true;
            })
            .catch(error => {
                this.error = error.body.message;
            });
    }

    // 🔹 Represented Candidates
    handleClickRepresented() {
        this.modalTitle = 'Represented to Client';
        getPresentedCandidates({ opportunityId: this.recordId })
            .then(result => {
                this.modalData = result.map(row => ({
                    Id: row.Id,
                    CandidateName: row.Candidate_Name__r?.Name,
                    CandidateUrl: '/' + row.Candidate_Name__r?.Id,
                    OpportunityName: row.Opportunity__r?.Name,
                    Status: row.Status__c
                }));

                this.columns = [
                    {
                        label: 'Candidate Name',
                        fieldName: 'CandidateUrl',
                        type: 'url',
                        typeAttributes: {
                            label: { fieldName: 'CandidateName' },
                            target: '_blank'
                        }
                    },
                    { label: 'Opportunity', fieldName: 'OpportunityName' },
                    { label: 'Status', fieldName: 'Status' }
                ];

                this.showModal = true;
            })
            .catch(error => {
                this.error = error.body.message;
            });
    }

    // 🔹 Close Modal
    closeModal() {
        this.showModal = false;
        this.modalData = [];
        this.columns = [];
    }
}