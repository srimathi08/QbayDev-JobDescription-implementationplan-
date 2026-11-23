import { LightningElement, api, wire, track } from 'lwc';
import getInterviewQuestions from '@salesforce/apex/InterviewQuestionRelatedOpp.getInterviewQuestions';

export default class InterviewQuestionsList extends LightningElement {
    @api recordId;
    @track questions = [];
    @track showModal = false;

    // Limit to first 5
    get limitedQuestions() {
        return this.questions.slice(0, 5);
    }

    get hasMore() {
        return this.questions.length > 5;
    }

    @wire(getInterviewQuestions, { opportunityId: '$recordId' })
    wiredQuestions({ data, error }) {
        if (data) {
            this.questions = data;
        } else if (error) {
            console.error('Error fetching questions:', error);
        }
    }

    openModal() {
        this.showModal = true;
    }

    closeModal() {
        this.showModal = false;
    }
}