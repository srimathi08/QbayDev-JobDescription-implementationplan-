import { LightningElement,track,wire } from 'lwc';
import { getListInfosByObjectName } from "lightning/uiListsApi";
import ACCOUNT_OBJECT from "@salesforce/schema/Opportunity";
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
//import ACCOUNT_OBJECT from '@salesforce/schema/Account';


export default class ToggleOpportunityView extends LightningElement {
 @track opportunities = [];
  @track showModal = false;
  @track showAccountModal = false;
  @track selectedAccountId;
  
  @track recordTypeOptions = [];
  @track selectedCreateRecordTypeId;

    @track isKanban = true;
    
     error;
      lists;
      @wire(getListInfosByObjectName, {
        objectApiName: ACCOUNT_OBJECT.objectApiName,
        pageSize: 10,
      })
      listOfLists({ error, data }) {
        if (data) {
          this.lists = data.lists;
          console.log('List of Lists:', JSON.stringify(this.lists));
          this.error = undefined;
          debugger;
        } else if (error) {
          this.error = error;
          this.lists = undefined;
          debugger;
        }
      }
/*@wire(getOpportunities)
  wiredOpportunities({ error, data }) {
    if (data) {
      this.opportunities = data;
    } else if (error) {
      console.error(error);
    }
  }*/

  @wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
  wiredAccountObjectInfo({ data, error }) {
    if (data) {
      // Build options from available record types
      const rtis = data.recordTypeInfos;
      this.recordTypeOptions = Object.keys(rtis)
        .filter(rtId => rtis[rtId].available)
        .map(rtId => {
          return { label: rtis[rtId].name, value: rtId };
        });

      // Optional: auto-select the first available record type
      if (this.recordTypeOptions.length > 0) {
        this.selectedCreateRecordTypeId = this.recordTypeOptions[0].value;
      }
    } else if (error) {
      console.error(error);
    }
  }


         get currentIcon() {
            return this.isKanban ? 'utility:list' : 'utility:kanban';
        }
    
        toggleView() {
            this.isKanban = !this.isKanban;
        }




  
  openModal() {
    this.showModal = true;
  }

 closeModal() {
console.log('Closing Opportunity modal');
this.showModal = false;
}

  openAccountModal() {
    this.showAccountModal = true;
  }

  closeAccountModal() {
console.log('Closing Account modal');
this.showAccountModal = false;
}
  handleOpportunitySuccess() {
    this.dispatchEvent(
      new ShowToastEvent({
        title: 'Success',
        message: 'Opportunity created',
        variant: 'success'
      })
    );
    this.showModal = false;
  }

  handleAccountSuccess(event) {
    const newAccountId = event.detail.id;
    this.selectedAccountId = newAccountId;
    this.showAccountModal = false;

    this.dispatchEvent(
      new ShowToastEvent({
        title: 'Success',
        message: 'New Account created and selected',
        variant: 'success'
      })
    );

    // After creating Account, update AccountId in Opportunity form
    const accountField = this.template.querySelector('lightning-input-field[field-name="AccountId"]');
    if (accountField) {
      accountField.value = newAccountId;
    }
  }

  handleAccountChange(event) {
    this.selectedAccountId = event.detail.value;
  }

  handleRecordTypeChange(event) {
    this.selectedCreateRecordTypeId = event.detail.value;
  }

  navigateToRecord(event) {
    const recordId = event.currentTarget.dataset.id;
    this[NavigationMixin.Navigate]({
      type: 'standard__recordPage',
      attributes: {
        recordId: recordId,
        objectApiName: 'Opportunity',
        actionName: 'view'
      }
    });
  }


}