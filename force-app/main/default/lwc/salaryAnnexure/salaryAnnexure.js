import { LightningElement, api, wire } from 'lwc';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';

import BASIC from '@salesforce/schema/Salary_Details__c.Basic_Pay_PF_Retirement_Benefits__c';
import OTHER from '@salesforce/schema/Salary_Details__c.Other_Allowances_Total__c';
import HRA from '@salesforce/schema/Salary_Details__c.House_Rent_Allowance_HRA__c';
import BUCKET from '@salesforce/schema/Salary_Details__c.Bucket_Allowances__c';
import GROSS from '@salesforce/schema/Salary_Details__c.Gross_Salary__c';
import PF_EMP from '@salesforce/schema/Salary_Details__c.EPF_Employee_Contribution_12__c';
import ESI_EMP from '@salesforce/schema/Salary_Details__c.ESI_Employee_contribution_0_75__c';
import PT from '@salesforce/schema/Salary_Details__c.PT_Annual__c';
import PF_ER from '@salesforce/schema/Salary_Details__c.PF_Contribution_Employer__c';
import ESI_ER from '@salesforce/schema/Salary_Details__c.ESI_Employer_contribution_3_25__c';
import HEALTH from '@salesforce/schema/Salary_Details__c.Health_Policy_Insurance__c';
import VAR_PAY from '@salesforce/schema/Salary_Details__c.Variable_Pay__c';
import NET from '@salesforce/schema/Salary_Details__c.Net_Salary_In_Hand__c';
import COMPANY from '@salesforce/schema/Salary_Details__c.Total_company_Contribution__c';
import CTC from '@salesforce/schema/Salary_Details__c.Total_CTC__c';

const FIELDS = [
    BASIC, OTHER, HRA, BUCKET, GROSS,
    PF_EMP, ESI_EMP, PT,
    PF_ER, ESI_ER, HEALTH,
    VAR_PAY, NET,
    COMPANY, CTC
];

export default class SalaryAnnexure extends LightningElement {
    @api recordId;
    record;

    @wire(getRecord, { recordId: '$recordId', fields: FIELDS })
    wiredRecord({ data, error }) {
        if (data) {
            this.record = data;
            console.log('Salary record loaded:', JSON.stringify(data));
        }
        if (error) {
            console.error('Error loading Salary record:', error);
        }
    }
    connectedCallback() {
        console.log('recordId:', this.recordId);
    }

    // ---- Annual values ----
    get basicPayAnnual() { return this.record ? getFieldValue(this.record, BASIC) || 0 : 0; }

    get otherAllowanceAnnual() { return this.record ? getFieldValue(this.record, OTHER) || 0 : 0; }
    get hraAnnual() { return this.record ? getFieldValue(this.record, HRA) || 0 : 0; }
    get bucketAnnual() { return this.record ? getFieldValue(this.record, BUCKET) || 0 : 0; }
    get grossAnnual() { return this.record ? getFieldValue(this.record, GROSS) || 0 : 0; }
    get pfEmpAnnual() { return this.record ? getFieldValue(this.record, PF_EMP) || 0 : 0; }
    get esiEmpAnnual() { return this.record ? getFieldValue(this.record, ESI_EMP) || 0 : 0; }
    get ptAnnual() { return this.record ? getFieldValue(this.record, PT) || 0 : 0; }

    // Calculated Total Deduction (Since field is missing)
    get totalDeductionAnnual() {
        return (this.pfEmpAnnual + this.esiEmpAnnual + this.ptAnnual);
    }

    get netSalaryAnnual() { return this.record ? getFieldValue(this.record, NET) || 0 : 0; }
    get pfEmployerAnnual() { return this.record ? getFieldValue(this.record, PF_ER) || 0 : 0; }
    get esiEmployerAnnual() { return this.record ? getFieldValue(this.record, ESI_ER) || 0 : 0; }
    get healthAnnual() { return this.record ? getFieldValue(this.record, HEALTH) || 0 : 0; }
    get companyContributionAnnual() { return this.record ? getFieldValue(this.record, COMPANY) || 0 : 0; }
    get variableAnnual() { return this.record ? getFieldValue(this.record, VAR_PAY) || 0 : 0; }
    get ctcAnnual() { return this.record ? getFieldValue(this.record, CTC) || 0 : 0; }

    // ---- Monthly values ----
    get basicPayMonthly() { return Math.round(this.basicPayAnnual / 12); }
    get otherAllowanceMonthly() { return Math.round(this.otherAllowanceAnnual / 12); }
    get hraMonthly() { return Math.round(this.hraAnnual / 12); }
    get bucketMonthly() { return Math.round(this.bucketAnnual / 12); }
    get grossMonthly() { 
        return this.basicPayMonthly + this.otherAllowanceMonthly + this.hraMonthly + this.bucketMonthly; 
    }
    get pfEmpMonthly() { return Math.round(this.pfEmpAnnual / 12); }
    get esiEmpMonthly() { return Math.round(this.esiEmpAnnual / 12); }
    get ptMonthly() { return Math.round(this.ptAnnual / 12); }
    get totalDeductionMonthly() { 
        return this.pfEmpMonthly + this.esiEmpMonthly + this.ptMonthly; 
    }
    get netSalaryMonthly() { 
        return this.grossMonthly - this.totalDeductionMonthly; 
    }
    get pfEmployerMonthly() { return Math.round(this.pfEmployerAnnual / 12); }
    get esiEmployerMonthly() { return Math.round(this.esiEmployerAnnual / 12); }
    get healthMonthly() { return Math.round(this.healthAnnual / 12); }
    get companyContributionMonthly() { 
        return this.pfEmployerMonthly + this.esiEmployerMonthly + this.healthMonthly; 
    }
    get variableMonthly() { return Math.round(this.variableAnnual / 12); }
    get ctcMonthly() { 
        return this.grossMonthly + this.companyContributionMonthly + this.variableMonthly; 
    }
}