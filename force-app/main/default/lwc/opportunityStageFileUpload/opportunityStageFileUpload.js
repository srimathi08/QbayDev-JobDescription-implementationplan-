/* { LightningElement, api, wire, track } from 'lwc';
import getStageFiles from '@salesforce/apex/OpportunityFileController.getStageFiles';
import updateFileStage from '@salesforce/apex/OpportunityFileController.updateFileStage';
import { getRecord } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Opportunity.StageName';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class OpportunityStageFileUpload extends LightningElement {
    @api recordId; // Opportunity Id
    @track stageName;
    @track fileData;
    @track showUpload = false;
    @track showFileLink = false;

    // Fetch current Opportunity StageName dynamically
    @wire(getRecord, { recordId: '$recordId', fields: [STAGE_FIELD] })
    wiredOpportunity({ error, data }) {
        if (data) {
            this.stageName = data.fields.StageName.value;
        } else if (error) {
            console.error('Error fetching stage:', error);
        }
    }

    // Get file(s) for this stage
    @wire(getStageFiles, { opportunityId: '$recordId', stageName: '$stageName' })
    wiredFiles({ data, error }) {
        if (data) {
            if (data.length > 0) {
                this.fileData = data[0];
                this.showFileLink = true;
                this.showUpload = false;
            } else {
                this.showFileLink = false;
                this.showUpload = true;
            }
        } else if (error) {
            console.error('Error fetching files:', error);
        }
    }

    // Handle upload completion
    handleUploadFinished(event) {
        const uploadedFiles = event.detail.files;
        const contentDocId = uploadedFiles[0].documentId;

        updateFileStage({ contentDocumentId: contentDocId, opportunityId: this.recordId })
            .then(() => {
                this.dispatchEvent(
                    new ShowToastEvent({
                        title: 'Success',
                        message: 'File uploaded and tagged to current stage.',
                        variant: 'success'
                    })
                );
                this.showFileLink = true;
                this.showUpload = false;
            })
            .catch(error => {
                console.error('Error tagging file:', error);
            });
    }
}  */

import { LightningElement, api, wire, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getStageFiles from '@salesforce/apex/OpportunityFileController.getStageFiles';
import updateFileStage from '@salesforce/apex/OpportunityFileController.updateFileStage';
import { getRecord } from 'lightning/uiRecordApi';
import STAGE_FIELD from '@salesforce/schema/Opportunity.StageName';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { refreshApex } from '@salesforce/apex';

export default class OpportunityStageFileUpload extends NavigationMixin(LightningElement) {
    @api recordId;
    @track stageName;
    @track fileList = []; // ✅ now supports multiple files
    wiredFileResult;

    // ✅ Get Opportunity stage
    @wire(getRecord, { recordId: '$recordId', fields: [STAGE_FIELD] })
    wiredOpportunity({ error, data }) {
        if (data) {
            this.stageName = data.fields.StageName.value;
        } else if (error) {
            console.error('Error fetching stage:', error);
        }
    }

    // ✅ Fetch all files for the current stage
    @wire(getStageFiles, { opportunityId: '$recordId', stageName: '$stageName' })
    wiredFiles(result) {
        this.wiredFileResult = result;
        const { data, error } = result;

        this.fileList = [];

        if (data && data.length > 0) {
            this.fileList = data; // store all matching files
        } else if (error) {
            console.error('Error fetching files:', JSON.stringify(error));
        }
    }

    // ✅ Handle file upload
    handleUploadFinished(event) {
        const uploadedFiles = event.detail.files;

        uploadedFiles.forEach(file => {
            const contentDocId = file.documentId;
            if (!contentDocId) return;

            updateFileStage({
                contentDocumentId: contentDocId,
                opportunityId: this.recordId
            })
                .then(() => {
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Success',
                            message: `${file.name} uploaded and tagged to current stage.`,
                            variant: 'success'
                        })
                    );
                    return refreshApex(this.wiredFileResult);
                })
                .catch(error => {
                    console.error('Error tagging file:', JSON.stringify(error));
                    this.dispatchEvent(
                        new ShowToastEvent({
                            title: 'Error',
                            message: 'Error tagging file: ' + (error.body?.message || ''),
                            variant: 'error'
                        })
                    );
                });
        });
    }

    // ✅ Open Salesforce file preview (for any clicked file)
    handleFileClick(event) {
        const contentDocId = event.currentTarget.dataset.id;

        if (contentDocId) {
            this[NavigationMixin.Navigate]({
                type: 'standard__namedPage',
                attributes: {
                    pageName: 'filePreview'
                },
                state: {
                    selectedRecordId: contentDocId
                }
            });
        } else {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: 'File preview not available.',
                    variant: 'error'
                })
            );
        }
    }

    // ✅ Download file (for any clicked Download button)
    handleDownloadClick(event) {
        const versionId = event.currentTarget.dataset.versionid;

        if (versionId) {
            window.open(`/sfc/servlet.shepherd/version/download/${versionId}`, '_blank');
        } else {
            this.dispatchEvent(
                new ShowToastEvent({
                    title: 'Error',
                    message: 'Download not available for this file.',
                    variant: 'error'
                })
            );
        }
    }
}