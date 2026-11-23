import { LightningElement, api, track } from 'lwc';
import updatePhotoOnAccount from '@salesforce/apex/UploadDocsController.updatePhotoOnAccount';

export default class UploadSupportingDocs extends LightningElement {
    @api recordId;
    @track openModal = false;

    // file names
    photoName;
    drivingName;
    panName;
    aadhaarName;
    tenthName;
    twelfthName;
    degreeName;
    pgName;
    salaryName;
    experienceName;
    OtherName;

    openTheModal() {
        this.openModal = true;
    }

    closeModal() {
        this.openModal = false;
    }

    submitDocs() {
        this.closeModal();
        alert('Documents uploaded successfully!');
    }

    // handlers
   /* handlePhotoUpload(event) {
        this.photoName = event.detail.files[0].name;
    } */   

handlePhotoUpload(event) {
    const file = event.detail.files[0];
    this.photoName = file.name;

    updatePhotoOnAccount({
        recordId: this.recordId,
        contentDocId: file.documentId
    })
    .then(() => {
        console.log('Photo mapped to Account successfully');
    })
    .catch(error => {
        console.error('Error updating photo: ', error);
    });
}

    handleDrivingUpload(event) {
    this.drivingName = event.detail.files[0].name;
    }
    handlePanUpload(event) {
        this.panName = event.detail.files[0].name;
    }
    handleAadhaarUpload(event) {
        this.aadhaarName = event.detail.files[0].name;
    }
    handleTenthUpload(event) {
        this.tenthName = event.detail.files[0].name;
    }
    handleTwelfthUpload(event) {
        this.twelfthName = event.detail.files[0].name;
    }
    handleDegreeUpload(event) {
        this.degreeName = event.detail.files[0].name;
    }
    handlePgUpload(event) {
        this.pgName = event.detail.files[0].name;
    }
    handleSalaryUpload(event) {
        this.salaryName = event.detail.files[0].name;
    }
    handleExperienceUpload(event) {
        this.experienceName = event.detail.files[0].name;
    }
    handleOtherUpload(event) {
        this.OtherName = event.detail.files[0].name;
    }
}