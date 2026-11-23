import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

import uploadFile from '@salesforce/apex/AttachmentController.uploadFile';
import createparent from '@salesforce/apex/AttachmentController.createparent';
import getPrompt from '@salesforce/apex/AttachmentController.getPrompt';
import getTodayUploadedFiles from '@salesforce/apex/AttachmentController.getTodayUploadedFiles';

export default class CandidatePdfUpload extends LightningElement {

    @track fileDataList = [];
    textFiles = [];

    isLoading = false;
    showAccountList = false;
    showModal = false;

    accounts = [];
    todayFiles = [];

    columns = [
    {
        label: 'Account Name',
        fieldName: 'accountUrl',
        type: 'url',
        typeAttributes: {
            label: { fieldName: 'accountName' },
            target: '_blank'
        }
    },
    {
        label: 'File Name',
        fieldName: 'fileName',
        type: 'text'
    },
    {
        label: 'Uploaded Date & Time',
        fieldName: 'createdDate',
        type: 'date',
        typeAttributes: {
            year: 'numeric',
            month: 'short',
            day: '2-digit',
            hour: '2-digit',
            minute: '2-digit'
        }
    }
];


    readFile(fileSource) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => {
                resolve({
                    fileName: fileSource.name,
                    base64: reader.result.split(',')[1]
                });
            };
            reader.onerror = () => reject(reader.error);
            reader.readAsDataURL(fileSource);
        });
    }

    async openfileUpload(event) {
        this.textFiles = await Promise.all(
            [...event.target.files].map(file => this.readFile(file))
        );

        this.fileDataList = this.textFiles.map(f => ({
            filename: f.fileName
        }));
    }

    async handleClick() {
        if (this.textFiles.length === 0) {
            this.showToast('Error', 'Please upload at least one file', 'error');
            return;
        }

        this.isLoading = true;

        try {
            const parentId = await createparent({
                fileName: this.textFiles[0].fileName
            });

            await Promise.all(
                this.textFiles.map(file =>
                    uploadFile({
                        base64: file.base64,
                        filename: file.fileName,
                        recordId: parentId
                    })
                )
            );

            await getPrompt({ recordId: parentId });

            this.showToast('Success', 'Files uploaded and processing started', 'success');

        } catch (e) {
            this.showToast('Error', e.body?.message || e.message, 'error');
        } finally {
            this.isLoading = false;
        }
    }

    async openTodayFilesModal() {
        this.isLoading = true;
        try {
            this.todayFiles = await getTodayUploadedFiles();
            this.showModal = true;
        } catch (e) {
            this.showToast('Error', 'Failed to load today files', 'error');
        } finally {
            this.isLoading = false;
        }
    }

    closeModal() {
        this.showModal = false;
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({ title, message, variant })
        );
    }
}