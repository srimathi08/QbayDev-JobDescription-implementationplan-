import { LightningElement, api, wire, track } from 'lwc';
import getAllMatches from '@salesforce/apex/OpportunityMatchHelper.getAllMatches';
import getOpportunityDetails from '@salesforce/apex/OpportunityMatchHelper.getOpportunityDetails';
//import saveInterview from '@salesforce/apex/OpportunityMatchHelper.saveInterview';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class OpportunityMatches extends LightningElement {
    @api recordId;
    @track matches;
    @track showModal = false;
    @track selectedCandidateId;
    @track selectedCandidateName;
    @track jobDescription;

    @track formData = {
        email: '',
        interviewer: '',
        scheduledDateTime: ''
    };

    // Get opportunity job description
    @wire(getOpportunityDetails, { opportunityId: '$recordId' })
    wiredOpportunity({ data, error }) {
        if (data) {
            this.jobDescription = data.Job_Description__c;
        } else if (error) {
            console.error('Error fetching opportunity details:', error);
        }
    }

    // Get matched candidates
    @wire(getAllMatches, { opportunityId: '$recordId' })
    wiredMatches({ data, error }) {
        if (data) {
            this.matches = data.map(match => ({
                ...match,
                accountId: match.Candidate_Name__r?.Id,
                accountName: match.Candidate_Name__r?.Name,
                accountUrl: `/lightning/r/Account/${match.Candidate_Name__r?.Id}/view`
            }));
        } else if (error) {
            console.error('Error fetching matches', error);
        }
    }

    get hasMatches() {
        return this.matches && this.matches.length > 0;
    }

   
    
handleScheduleClick(event) {
    this.selectedCandidateId = event.currentTarget.dataset.id;
    this.selectedCandidateName = event.currentTarget.dataset.name;
    this.showModal = true;

    // Wait for modal to render before setting value
    setTimeout(() => {
        const candidateField = this.template.querySelector('.candidateField');
        if (candidateField) {
            candidateField.value = this.selectedCandidateId;
        }

        const opportunityField = this.template.querySelector('.opportunityField');
        if (opportunityField) {
            opportunityField.value = this.recordId;
        }

        const jobDescField = this.template.querySelector('.jobDescField');
        if (jobDescField) {
            jobDescField.value = this.jobDescription;
        }
    }, 0);
}

    handleCloseModal() {
        this.showModal = false;
        this.resetFields();
    }

    handleInputChange(event) {
        const { name, value } = event.target;
        this.formData = { ...this.formData, [name]: value };
    }

handleSave() {
    const form = this.template.querySelector('lightning-record-edit-form');
    if (form) {
        form.submit(); 
    }
} 

handleSuccess(event) {
    this.showToast('Success', 'Interview saved successfully', 'success');
    this.resetFields();
    this.showModal = false;
}

handleError(event) {
    console.error('Interview save failed', event.detail);
    this.showToast('Error', event.detail.message, 'error');
}

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant,
            mode: 'dismissable'
        }));
    }

    resetFields() {
        this.formData = {
            email: '',
            interviewer: '',
            scheduledDateTime: ''
        };
    }

renderedCallback() {
    console.log('Component rendered');
}

testClick() {
    console.log('Test button click working!');
}

@wire(getAllMatches, { opportunityId: '$recordId' })
wiredMatches({ data, error }) {
    if (data) {
        this.matches = data.map(match => {
            const score = Number(match.Match_Score__c);
            let barClass = 'bar-red';

            if (score >= 8) {
                barClass = 'bar-green';
            } else if (score >= 6) {
                barClass = 'bar-orange';
            }

            return {
                ...match,
                accountId: match.Candidate_Name__r?.Id,
                accountName: match.Candidate_Name__r?.Name,
                accountUrl: `/lightning/r/Account/${match.Candidate_Name__r?.Id}/view`,
                barClass,
                barStyle: `width:${score * 10}%`
            };
        });
    }
}


}