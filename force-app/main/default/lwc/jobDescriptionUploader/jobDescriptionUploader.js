/*import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import uploadFile from '@salesforce/apex/JD_AttachmentController.uploadFile';
import createParent from '@salesforce/apex/JD_AttachmentController.createParent';
import getPrompt from '@salesforce/apex/JD_AttachmentController.getPrompt';

export default class JdPdfUpload extends LightningElement {
    @track fileDataList = [];
    textFiles = [];
    isLoading = false;
    showJDList = false;
    jobDescriptions = [];

    readFile(fileSource) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            const fileName = fileSource.name;
            reader.onerror = () => reject(reader.error);
            reader.onload = () => resolve({ fileName, base64: reader.result.split(',')[1] });
            reader.readAsDataURL(fileSource);
        });
    }

    async openfileUpload(event) {
        this.textFiles = await Promise.all([...event.target.files].map(file => this.readFile(file)));
        this.fileDataList = this.textFiles.map(file => ({ filename: file.fileName }));
    }

    async handleClick() {
        if (this.textFiles.length === 0) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: 'Please upload at least one file.', variant: 'error' }));
            return;
        }
        this.isLoading = true;
        try {
            const parentId = await createParent({ fileName: this.textFiles[0].fileName });
            const uploadPromises = this.textFiles.map(file =>
                uploadFile({ base64: file.base64, filename: file.fileName, recordId: parentId })
            );
            await Promise.all(uploadPromises);
            const promptResponse = await getPrompt({ recordId: parentId });
            this.jobDescriptions = promptResponse.map(str => {
                const [id, name, skills] = str.split(':');
                return { id, name, skills, link: `/${id}` };
            });
            this.showJDList = true;
            this.dispatchEvent(new ShowToastEvent({ title: 'Success', message: 'Files processed successfully.', variant: 'success' }));
        } catch (error) {
            this.dispatchEvent(new ShowToastEvent({ title: 'Error', message: error.body.message, variant: 'error' }));
        } finally {
            this.isLoading = false;
        }
    }
}
*/

import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import uploadFile from '@salesforce/apex/JD_AttachmentController.uploadFile';
import createParent from '@salesforce/apex/JD_AttachmentController.createParent';
import getPrompt from '@salesforce/apex/JD_AttachmentController.getPrompt';

export default class JdPdfUpload extends LightningElement {
    @track fileDataList = [];
    textFiles = [];
    isLoading = false;
    showJDList = false;
    jobDescriptions = [];

    readFile(fileSource) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            const fileName = fileSource.name;
            reader.onerror = () => reject(reader.error);
            reader.onload = () => resolve({ fileName, base64: reader.result.split(',')[1] });
            reader.readAsDataURL(fileSource);
        });
    }

    async openfileUpload(event) {
        this.textFiles = await Promise.all([...event.target.files].map(file => this.readFile(file)));
        this.fileDataList = this.textFiles.map(file => ({ filename: file.fileName }));
    }

    async handleClick() {
        if (this.textFiles.length === 0) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Error', message: 'Please upload at least one file.', variant: 'error' })
            );
            return;
        }

        this.isLoading = true;
        try {
            // Create parent JD_Sample__c record
            const parentId = await createParent({ fileName: this.textFiles[0].fileName });

            // Upload all files
            const uploadPromises = this.textFiles.map(file =>
                uploadFile({ base64: file.base64, filename: file.fileName, recordId: parentId })
            );
            await Promise.all(uploadPromises);

            // Get prompt response
            const promptResponse = await getPrompt({ recordId: parentId });

            // Parse only the last created JD (new one)
            if (promptResponse && promptResponse.length > 0) {
                const latest = promptResponse[promptResponse.length - 1];
                const [id, name, role] = latest.split(':');
                this.jobDescriptions = [{ id, name, role, link: `/${id}` }];
                this.showJDList = true;
            }

            this.dispatchEvent(
                new ShowToastEvent({ title: 'Success', message: 'File processed successfully.', variant: 'success' })
            );
        } catch (error) {
            this.dispatchEvent(
                new ShowToastEvent({ title: 'Error', message: error.body?.message || error.message, variant: 'error' })
            );
        } finally {
            this.isLoading = false;
        }
    }
}