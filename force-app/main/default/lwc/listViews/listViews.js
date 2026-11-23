import { LightningElement, wire,api } from "lwc";
import { getListRecordsByName } from "lightning/uiListsApi";
import ACCOUNT_OBJECT from "@salesforce/schema/Opportunity";
import { NavigationMixin } from 'lightning/navigation'
export default class ListViews extends NavigationMixin(LightningElement) {
    error;
  records;
  @api listviewname;
  @wire(getListRecordsByName, {
    objectApiName: ACCOUNT_OBJECT.objectApiName,
    listViewApiName: "$listviewname",
    fields: ["Opportunity.Id", "Opportunity.Name", "Opportunity.StageName","Opportunity.Amount"],
    sortBy: ["Opportunity.Name"],
    pageSize: 1000,
    pageToken: "$pageToken",
  })
  listRecords({ error, data }) {
    if (data) {
      this.records = data.records;
      console.log('data', JSON.stringify(data));
      this.nextPageToken = data?.nextPageToken;
      this.error = undefined;
    } else if (error) {
      this.error = error;
    }
  }

  handleNextPage(event) {
    event.stopPropagation();
    if (this.nextPageToken) {
      this.pageToken = this.nextPageToken;
    }
  }

  navigateOppHandler(event){
        event.preventDefault()
         console.log('event id called',event.target.dataset.id)
        this.navigateHandler(event.target.dataset.id, 'Opportunity')
    }
    navigateAccHandler(event){
        event.preventDefault()
        this.navigateHandler(event.target.dataset.id, 'Account')
    }
    navigateHandler(Id, apiName) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: Id,
                objectApiName: apiName,
                actionName: 'view',
            },
        });
    }
  
}