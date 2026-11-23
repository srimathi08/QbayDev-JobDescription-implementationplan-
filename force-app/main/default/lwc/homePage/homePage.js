import { LightningElement ,track, wire } from 'lwc';
import { NavigationMixin  } from 'lightning/navigation';
import { getObjectInfo } from 'lightning/uiObjectInfoApi';
import ACCOUNT_OBJECT from '@salesforce/schema/Account';

export default class HomePage extends NavigationMixin(LightningElement) {

@track showCreateMenu = false;
@track showOpportunityModal = false;
@track showAccountModal = false;
@track showContactModal = false;
@track showInlineAccountModalForOpportunity = false;
@track selectedAccountIdForOpportunity;

@track selectedCreateRecordTypeId;
@track recordTypeOptions = [];

  @track showFeedModal = false;

@wire(getObjectInfo, { objectApiName: ACCOUNT_OBJECT })
wiredAccountObjectInfo({ data, error }) {
if (data) {
const rtis = data.recordTypeInfos;
this.recordTypeOptions = Object.keys(rtis)
.filter(rtId => rtis[rtId].available)
.map(rtId => {
return { label: rtis[rtId].name, value: rtId };
});

  if (this.recordTypeOptions.length > 0) {
    this.selectedCreateRecordTypeId = this.recordTypeOptions[0].value;
  }
} else if (error) {
  console.error(error);
}
}




     handleDeals() {
        this[NavigationMixin.Navigate]({
            type: 'standard__component',
            attributes: {
                componentName: 'c__toggleOpportunityView',
            }
        });
    }


openCreateMenu() {
this.showCreateMenu = true;
}

closeCreateMenu() {
this.showCreateMenu = false;
this.showOpportunityModal = false;
this.showAccountModal = false;
this.showContactModal = false;
}

createAccount() {
this.closeCreateMenu();
this.showAccountModal = true;
}

createContact() {
this.closeCreateMenu();
this.showContactModal = true;
}

createOpportunity() {
this.closeCreateMenu();
this.showOpportunityModal = true;
}

closeModal() {
this.showOpportunityModal = false;
}

handleOpportunitySuccess() {
this.closeModal();
// Optionally show toast or refresh data
}

openInlineAccountForOpportunity() {
this.showInlineAccountModalForOpportunity = true;
}

closeInlineAccountForOpportunity() {
this.showInlineAccountModalForOpportunity = false;
}

handleInlineAccountCreatedForOpportunity(event) {
this.selectedAccountIdForOpportunity = event.detail.id;
this.closeInlineAccountForOpportunity();
}

handleAccountSuccess() {
this.showAccountModal = false;
// You can add toast here
}

handleContactSuccess() {
this.showContactModal = false;
// You can add toast here
}

openRecordModal(objectName) {
this[NavigationMixin.Navigate]({
type: 'standard__objectPage',
attributes: {
objectApiName: objectName,
actionName: 'new'
}
});
}

handleMarketingEmail(){
  const pageRef = {
      type: "standard__quickAction",
      attributes: {
        apiName: "Global.SendEmail",
      },
      state: {
        
        recordId: "001fs000000nXSnAAM"
        
      }
    };

    this[NavigationMixin.Navigate](pageRef);
  }

 handleFeed() {
    this[NavigationMixin.Navigate]({
        type: 'standard__component',
        attributes: {
            componentName: 'c__myTasks', // your Task LWC
        }
    });
}


    closeFeed() {
        this.showFeedModal = false;
        document.body.style.overflow = ''; // restore scroll
    }

}