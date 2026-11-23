import { LightningElement, api, wire, track } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import { updateRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from "lightning/refresh";
import memberAvatar from '@salesforce/resourceUrl/member';
import NAME_FIELD          from '@salesforce/schema/Account.Name';
import DESIGNATION_FIELD from '@salesforce/schema/Account.Designation__c';
import IMAGE_FIELD from '@salesforce/schema/Account.Image__c';
import AGE_FIELD from '@salesforce/schema/Account.Age__c'
import TOTAL_YEAR_FIELD from '@salesforce/schema/Account.Years_of_Experience__c'
import PHONE_FIELD from '@salesforce/schema/Account.Phone'
import WORKEMAIL_FIELD from '@salesforce/schema/Account.Employee_Email__c';
import EMPID_FIELD from '@salesforce/schema/Account.Employee_ID__c';
import ID_FIELD from '@salesforce/schema/Account.Id';
const FIELDS = [NAME_FIELD, DESIGNATION_FIELD, IMAGE_FIELD,AGE_FIELD,PHONE_FIELD,WORKEMAIL_FIELD,EMPID_FIELD,TOTAL_YEAR_FIELD];
export default class SingleCandidateTracker extends LightningElement {
     
     @api recordId;
     // Replace with your static resource or import logic
    avatarUrl = memberAvatar;   
    @track showModal = false;
    @track imageRichText='';
     @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
     account;

   // Convenience getters make the template cleaner
     get name() {
        console.log('Account data:', JSON.stringify(this.account.data));

         return this.account.data?.fields.Name.value;
     }

     get employeeId() {
         return this.account.data?.fields.Employee_ID__c.value || '';
     }

     get image(){
        return this.account.data?.fields.Image__c.value || '<img src="' + this.avatarUrl + '" />';
     }

     /*get gender(){
        return this.account.data?.fields.PersonGenDER.value || 'Gender';
     }*/

     get designation() {
        return this.account.data?.fields.Designation__c.value || 'Designation';
    }

    get age(){
        return this.account.data?.fields.Age__c.value || '';
    }
    
 get toatlYears(){
        return this.account.data?.fields.Years_of_Experience__c.value || 'Total Years of Experience:';
    
    }

    get phone(){
        return this.account.data?.fields.Phone.value || 'Phone';
    }
    
    get email(){
        return this.account.data?.fields.Employee_Email__c.value || 'Email';
    }

/*get ageLabel() {
        return `Age ${this.age}`;
    }*/


    get ageLabel() {
        return `${this.toatlYears} Yrs Exp`;
    }

    handleUploadClick(event){
        this.showModal = true;

    }

    openfileUpload(event){
                const file = event.target.files[0];
        if (!file) return;

        const reader = new FileReader();
        reader.onload = () => {
            const base64 = reader.result;
            this.imageRichText = `<img src="${base64}" style="border-radius: 50%; width:100px; height:100px;" />`;
        };
        reader.readAsDataURL(file);
        console.log('File uploaded:', this.imageRichText);
    }

    handleModalClose() {
        this.showModal = false;
    }

    handleSubmit(){
        this.showModal = false;
        const fields = {};
        if (this.imageRichText) {
            fields[IMAGE_FIELD.fieldApiName] = this.imageRichText;
        }
         if ( 
            Object.keys( fields ).length > 0 
        ) {
            fields[ ID_FIELD.fieldApiName ] = this.recordId;
            const recordInput = { fields }; 
            updateRecord( recordInput )
            .then( () => {

                this.dispatchEvent(
                    new RefreshEvent()
                );
                this.dispatchEvent(
                    new ShowToastEvent( {
                        title: 'Success',
                        message: 'Image Successfully uploaded',
                        variant: 'success'
                    } )
                );

            } ).catch( error => {

                this.dispatchEvent(
                    new ShowToastEvent( {
                        title: 'Error updating Image',
                        message: error.body.message,
                        variant: 'error'
                    } )
                );

            } );

        } else {

            this.dispatchEvent(
                new ShowToastEvent( {
                    title: 'Error updating Image',
                    message: 'Please upload Image',
                    variant: 'error'
                } )
            );

        }
    }
}