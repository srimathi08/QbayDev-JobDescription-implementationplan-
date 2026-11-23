import { LightningElement, api, wire, track } from 'lwc';
import getRoleCategories from '@salesforce/apex/RoleResponsibilityController.getRoleCategories';
import getResponsibilities from '@salesforce/apex/RoleResponsibilityController.getResponsibilities';
import getAssignedResponsibilities from '@salesforce/apex/RoleResponsibilityController.getAssignedResponsibilities';
import saveResponsibilities from '@salesforce/apex/RoleResponsibilityController.saveResponsibilities';

import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class AssignRolesResponsibilities extends LightningElement {

    @api recordId;
    @api objectApiName;

    @track roleOptions = [];
    @track selectedRoles = [];
    @track responsibilities = [];
    @track selectedResponsibilities = [];

    @track isLoading = false;  // SPINNER CONTROL

    // Fetch Roles
    @wire(getRoleCategories)
    wiredRoles({ data }) {
        if (data) {
            this.roleOptions = data.map(role => ({
                label: role.Name,
                value: role.Id
            }));
        }
    }

    // Role Change
    handleRoleChange(event) {
        this.selectedRoles = event.detail.value;

        if (this.selectedRoles.length > 0) {

            this.isLoading = true; 

            getResponsibilities({ roleIds: this.selectedRoles })
                .then(result => {
                    this.responsibilities = result;
                    return getAssignedResponsibilities({
                        recordId: this.recordId,
                        objectApiName: this.objectApiName
                    });
                })
                .then(existingIds => {
                    this.selectedResponsibilities = existingIds; // PRESELECT
                })
                .finally(() => {
                    this.isLoading = false; 
                });
        }
    }

    // RESPONSIBILITY FIXED LOGIC 
    handleResponsibilityChange(event) {

        const newlySelected = event.detail.value;

        let updatedSelections = new Set(this.selectedResponsibilities);

        newlySelected.forEach(id => updatedSelections.add(id));

        const checkboxOptions = event.target.options.map(opt => opt.value);

        checkboxOptions.forEach(id => {
            if (!newlySelected.includes(id)) {
                updatedSelections.delete(id);
            }
        });

        this.selectedResponsibilities = Array.from(updatedSelections);
    }

    // GROUPING LOGIC (same)
    get groupedResponsibilities() {
        if (!this.responsibilities.length) return null;

        let map = {};

        this.responsibilities.forEach(res => {
            const roleName = res.Role_Category__r.Name;

            if (!map[roleName]) {
                map[roleName] = [];
            }

            map[roleName].push({
                label: res.Name,
                value: res.Id
            });
        });

        return Object.keys(map).map(roleName => ({
            roleName,
            responsibilities: map[roleName]
        }));
    }

    // SAVE WITH SPINNER 
    handleSave() {

        if(!this.selectedResponsibilities.length) {
            this.showToast('Error', 'Select at least one Responsibility', 'error');
            return;
        }

        this.isLoading = true; 

        saveResponsibilities({
            recordId: this.recordId,
            objectApiName: this.objectApiName,
            responsibilityIds: this.selectedResponsibilities
        })
        .then(() => {
            this.showToast('Success', 'Responsibilities Assigned', 'success');
        })
        .catch(error => {
            this.showToast('Error', error.body.message, 'error');
        })
        .finally(() => {
            this.isLoading = false; 
        });
    }

    showToast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}