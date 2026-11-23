import { LightningElement, wire,track,api} from 'lwc';
//import { getListUi } from 'lightning/uiListApi';
import { getListRecordsByName } from "lightning/uiListsApi";
import { updateRecord } from 'lightning/uiRecordApi';
import { refreshApex } from '@salesforce/apex';
import { getPicklistValues, getObjectInfo } from 'lightning/uiObjectInfoApi';
import OPPORTUNITY_OBJECT from '@salesforce/schema/Opportunity'
import STAGE_FIELD from '@salesforce/schema/Opportunity.StageName'
import ID_FIELD from '@salesforce/schema/Opportunity.Id'
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class DragAndDropLwc extends LightningElement {
    results 
    records
    pickVals
    recordId
    searchKey
    @api listviewname
     @track showDropdown = false;
    @track selectedSort=["-Opportunity.Name"];
    @track stageTotals = [];

    /*** fetching Opportunity lists ***/
    // @wire(getListUi, {
    //     objectApiName: OPPORTUNITY_OBJECT,
    //     listViewApiName:'$listviewname'
    // })wiredListView({error, data}){
    //     if(data){
    //         console.log("lenth", data.records.records.length)
    //         this.results = data.records.records.length;
    //         if(this.results === 0 || this.results === 1){
    //             this.results+=' result'
    //         }  else {
    //             this.results+=' results'
    //         }
    //         this.records = data.records.records.map(item => {
    //             let field = item.fields
    //             let account = field.Account.value.fields
    //             return { 'Id': field.Id.value, 'Name': field.Name.value, 'AccountId': account.Id.value, 'AccountName': account.Name.value, 'CloseDate': field.CloseDate.value, 'StageName': field.StageName.value, 'Amount': field.Amount.value }

    //         })
    //     }
    //     if(error){
    //         console.error(error)
    //     }
    // }


    @wire(getListRecordsByName, {
    objectApiName: OPPORTUNITY_OBJECT.objectApiName,
    listViewApiName: "$listviewname",
    fields: ["Opportunity.Id","Opportunity.AccountId","Opportunity.CloseDate", "Opportunity.Name", "Opportunity.StageName","Opportunity.Amount", "Opportunity.Account.Name"],
    sortBy: "$selectedSort",
    pageSize: 1000,
    pageToken: "$pageToken",
    searchTerm:'$searchKey'
  })
  listRecords({ error, data }) {
    if (data) {
      this.results = data.records.length;  
      if(this.results === 0 || this.results === 1){
            this.results+=' result'
         }  else {
             this.results+=' results'
             }
      this.records = data.records;
      console.log('data', JSON.stringify(data));
      this.records = data.records.map(item => {
    let field = item.fields;
    let account = field.Account?.value?.fields || {};
    return {
        Id: field.Id.value,
        Name: field.Name.value,
        StageName: field.StageName.value,
        Amount: field.Amount.value,
        AccountId: field.AccountId?.value || null,
        AccountName: account.Name?.value || null,
        CloseDate: field.CloseDate?.value || null,
    };
});
        const totalsMap = {};
        this.records.forEach(record => {
            const stage = record.StageName;
            const amount = record.Amount || 0;

            if (!totalsMap[stage]) {
                totalsMap[stage] = { totalAmount: 0, recordCount: 0 };
            }

            totalsMap[stage].totalAmount += amount;
            totalsMap[stage].recordCount += 1;
        });

        // Convert to array
        // this.stageTotals = Object.keys(totalsMap).map(stage => {
        //     return {
        //         stageName: stage,
        //         totalAmount: totalsMap[stage].totalAmount,
        //         recordCount: totalsMap[stage].recordCount
        //     };
        // });

        this.stageTotals = this.pickVals.map(stage => {
    return {
        stageName: stage,
        totalAmount: totalsMap[stage]?.totalAmount || 0,
        recordCount: totalsMap[stage]?.recordCount || 0
    };
});


        this.stageTotals.sort((a, b) => {
            return this.pickVals.indexOf(a.stageName) - this.pickVals.indexOf(b.stageName);
        }); 


        console.log('Stage Totals:', JSON.stringify(this.stageTotals));
      this.nextPageToken = data?.nextPageToken;
      this.error = undefined;
    } else if (error) {
      this.error = error;
    }
  }




/** Fetch metadata abaout the opportunity object**/
@wire(getObjectInfo, {objectApiName:OPPORTUNITY_OBJECT})
objectInfo
/*** fetching Stage Picklist ***/

    @wire(getPicklistValues, {
        recordTypeId:'$objectInfo.data.defaultRecordTypeId',
        fieldApiName:STAGE_FIELD
    })stagePicklistValues({ data, error}){
        if(data){
            console.log("Stage Picklist", data)
            this.pickVals = data.values.map(item => item.value)
            console.log("Picklist Values", JSON.stringify(this.pickVals))
        }
        if(error){
            console.error(error)
        }
    }


    /****getter to calculate the  width dynamically*/
    get calcWidth(){        
        let len = this.pickVals.length +1
        console.log(`width: calc(100vw/ ${len})`)
        return `width: calc(100vw/ ${len})`
    }

    handleListItemDrag(event){
        this.recordId = event.detail
    }

    handleItemDrop(event){
        let stage = event.detail
        // this.records = this.records.map(item=>{
        //     return item.Id === this.recordId ? {...item, StageName:stage}:{...item}
        // })
        this.updateHandler(stage)
    }
    updateHandler(stage){
        const fields = {};
        fields[ID_FIELD.fieldApiName] = this.recordId;
        fields[STAGE_FIELD.fieldApiName] = stage;
        const recordInput ={fields}
        updateRecord(recordInput)
        .then(()=>{
            console.log("Updated Successfully")
            this.showToast()
            return refreshApex(this.wiredListView)
        }).catch(error=>{
            console.error(error)
        })
    }

    showToast(){
        this.dispatchEvent(
            new ShowToastEvent({
                title:'Success',
                message:'Stage updated Successfully',
                variant:'success'
            })
        )
    }


    handleInputChange(event){
        this.searchKey = event.target.value;
        console.log('Search Key:', this.searchKey);
        // You can implement search logic here if needed
    }

    
    toggleDropdown() {
        this.showDropdown = !this.showDropdown;
    }

    selectSort(event) {
        const selectedOption = event.target.dataset.value;
        this.selectedSort =[`${selectedOption}`]
        console.log('Selected Sort:', JSON.stringify(this.selectedSort));
        this.showDropdown = false;
        // You can add sort logic here
    }
}