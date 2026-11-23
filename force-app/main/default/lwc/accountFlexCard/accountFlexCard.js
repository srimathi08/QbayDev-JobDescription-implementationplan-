import { LightningElement, api, wire } from 'lwc';
import getInterviewSummary from '@salesforce/apex/AccountFlexSummary.getInterviewSummary';

export default class AccountFlexCard extends LightningElement {
    @api recordId; // Account Id passed when component is on Account record page
    summary;
    error;

    @wire(getInterviewSummary, { accountId: '$recordId' })
    wiredSummary({ error, data }) {
        if (data) {
            this.summary = data;
            this.error = undefined;
        } else if (error) {
            this.summary = undefined;
            this.error = error.body.message;
        }
    }
}