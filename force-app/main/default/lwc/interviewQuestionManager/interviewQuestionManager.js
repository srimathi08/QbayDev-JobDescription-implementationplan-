/*import { LightningElement, track, api } from 'lwc';
import saveInterviewQuestions from '@salesforce/apex/InterviewQuestionController.saveInterviewQuestions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class InterviewQuestions extends LightningElement {
    @api candidateId;
    @api opportunityId;
    @api interviewDate;

    @track questions = [{ id: 1, text: '', label: 'Question 1' }];
    questionCounter = 1;

    addQuestion() {
        this.questionCounter++;
        this.questions = [
            ...this.questions,
            { id: this.questionCounter, text: '', label: `Question ${this.questionCounter}` }
        ];
    }

    removeQuestion(event) {
        const id = parseInt(event.target.dataset.id, 10);
        this.questions = this.questions.filter(q => q.id !== id);
    }

    handleQuestionChange(event) {
        const id = parseInt(event.target.dataset.id, 10);
        const value = event.target.value;
        this.questions = this.questions.map(q =>
            q.id === id ? { ...q, text: value } : q
        );
    }

    saveQuestions() {
        const filledQuestions = this.questions
            .map(q => q.text.trim())
            .filter(q => q.length > 0);

        if (filledQuestions.length === 0) {
            this.showToast('Error', 'Please enter at least one question.', 'error');
            return;
        }

        saveInterviewQuestions({
            candidateId: this.candidateId,
            opportunityId: this.opportunityId,
            interviewDate: this.interviewDate,
            questions: filledQuestions
        })
        .then(() => {
            this.showToast('Success', 'Interview questions saved successfully', 'success');
            this.questions = [{ id: 1, text: '', label: 'Question 1' }];
            this.questionCounter = 1;
        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}*/ 

           

import { LightningElement, track } from 'lwc';
import saveInterviewQuestions from '@salesforce/apex/InterviewQuestionController.saveInterviewQuestions';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class InterviewQuestionModal extends LightningElement {
    candidateId;
    opportunityId;
    interviewDate;
    @track questions = [{ id: 1, label: 'Question 1', value: '' }];
    questionCounter = 1;

    handleCandidateChange(event) {
        this.candidateId = event.detail.value[0]; // lookup returns array
    }

    handleOpportunityChange(event) {
        this.opportunityId = event.detail.value[0];
    }

    handleDateChange(event) {
        this.interviewDate = event.target.value;
    }

    handleQuestionChange(event) {
        const index = event.target.dataset.index;
        this.questions[index].value = event.target.value;
    }

    addQuestion() {
        this.questionCounter++;
        this.questions = [
            ...this.questions,
            { id: this.questionCounter, label: `Question ${this.questionCounter}`, value: '' }
        ];
    }

    removeQuestion(event) {
        const index = event.target.dataset.index;
        this.questions.splice(index, 1);
        this.questions = [...this.questions];
    }

    saveQuestions() {
        const questionValues = this.questions
            .map(q => q.value.trim())
            .filter(val => val.length > 0);

        if (!this.candidateId || !this.opportunityId || !this.interviewDate) {
            this.showToast('Error', 'Please fill all required fields', 'error');
            return;
        }

        if (questionValues.length === 0) {
            this.showToast('Error', 'Please enter at least one question', 'error');
            return;
        }

        saveInterviewQuestions({
            candidateId: this.candidateId,
            opportunityId: this.opportunityId,
            interviewDate: this.interviewDate,
            questions: questionValues
        })
        .then(() => {
            this.showToast('Success', 'Interview questions saved successfully', 'success');
            this.resetForm();
        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        });
    }

    resetForm() {
        this.candidateId = '';
        this.opportunityId = '';
        this.interviewDate = '';
        this.questions = [{ id: 1, label: 'Question 1', value: '' }];
        this.questionCounter = 1;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}