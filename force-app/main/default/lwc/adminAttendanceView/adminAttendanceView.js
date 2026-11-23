import { LightningElement, track } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

// Import Apex Methods
import getAdminAttendanceRecords from '@salesforce/apex/AdminAttendanceViewController.getAdminAttendanceRecords';
import getDepartments from '@salesforce/apex/AdminAttendanceViewController.getDepartments';
import exportAttendanceToCSV from '@salesforce/apex/AdminAttendanceViewController.exportAttendanceToCSV';
import searchEmployeesLightweight from '@salesforce/apex/AdminAttendanceViewController.searchEmployeesLightweight';
export default class AdminAttendanceView extends LightningElement {
    
    // ============================================
    // STATE PROPERTIES
    // ============================================
    
    @track isLoading = false;
    @track filtersExpanded = true;
    @track hasError = false;
    @track errorMessage = '';
    
    // Filter Values
    @track employeeIdFilter = '';
    @track employeeNameFilter = '';
    @track departmentFilter = '';
    @track startDate = '';
    @track endDate = '';
    
    // Table Data
    @track displayedRecords = [];
    @track allRecords = [];
    
    // Sorting
    @track sortedBy = '';
    @track sortDirection = 'asc';
    
    // Pagination
    @track pageSize = 20;
    @track currentPage = 1;
    @track totalRecords = 0;
    @track totalPages = 0;
    
    // Dropdown Options
    @track employeeIdOptions = [];
    @track employeeNameOptions = [];
    @track departmentOptions = [];

    // Employee Search Suggestions
@track employeeIdSuggestions = [];
@track employeeNameSuggestions = [];
@track showEmployeeIdSuggestions = false;
@track showEmployeeNameSuggestions = false;
    
    // ✅ NEW: Track if filters have been applied
    @track filtersHaveBeenApplied = false;
    
    // ============================================
    // LIFECYCLE HOOKS
    // ============================================
    
    connectedCallback() {
        console.log('=== Admin Attendance View Initialized ===');
        this.initializeComponent();
        // ✅ NEW: Add event listener to close suggestions when clicking outside
        document.addEventListener('click', this.handleDocumentClick.bind(this));
    }

    disconnectedCallback() {
    // ✅ NEW: Clean up event listener
    document.removeEventListener('click', this.handleDocumentClick.bind(this));
}
   
    handleDocumentClick(event) {
    // Close suggestions if clicking outside the search fields
    const empIdField = this.template.querySelector('[name="employeeId"]');
    const empNameField = this.template.querySelector('[name="employeeName"]');
    
    if (empIdField && !empIdField.contains(event.target)) {
        // Small delay to allow suggestion click to register first
        setTimeout(() => {
            this.showEmployeeIdSuggestions = false;
        }, 200);
    }
    
    if (empNameField && !empNameField.contains(event.target)) {
        setTimeout(() => {
            this.showEmployeeNameSuggestions = false;
        }, 200);
    }
}

    initializeComponent() {
        // Set default date range (last 7 days)
        const today = new Date();
        const sevenDaysAgo = new Date();
        sevenDaysAgo.setDate(today.getDate() - 7);
        
        this.startDate = this.formatDateForInput(sevenDaysAgo);
        this.endDate = this.formatDateForInput(today);
        
        console.log('Default date range:', this.startDate, 'to', this.endDate);
      
        this.loadDepartments();
        
        // ✅ CHANGED: DO NOT load initial data - wait for user to apply filters
        console.log('✅ Waiting for user to apply filters before loading data');
    }
    
   //Load Employee IDs for dropdown
    loadEmployeeIds() {
        getEmployeeIds()
            .then(result => {
                console.log('Employee IDs loaded:', result.length);
                
                const idOptions = [{ label: 'All Employee IDs', value: '' }];
                
                if (result && result.length > 0) {
                    result.forEach(option => {
                        idOptions.push({
                            label: option.label,
                            value: option.value
                        });
                    });
                }
                
                this.employeeIdOptions = idOptions;
                console.log('Employee ID options:', this.employeeIdOptions.length);
                
            })
            .catch(error => {
                console.error('Error loading Employee IDs:', error);
                this.employeeIdOptions = [{ label: 'All Employee IDs', value: '' }];
            });
    }
    
       //Load Employee Names for dropdown
    
    loadEmployeeNames() {
        getEmployeeNames()
            .then(result => {
                console.log('Employee Names loaded:', result.length);
                
                const nameOptions = [{ label: 'All Employees', value: '' }];
                
                if (result && result.length > 0) {
                    result.forEach(option => {
                        nameOptions.push({
                            label: option.label,
                            value: option.value
                        });
                    });
                }
                
                this.employeeNameOptions = nameOptions;
                console.log('Employee Name options:', this.employeeNameOptions.length);
                
            })
            .catch(error => {
                console.error('Error loading Employee Names:', error);
                this.employeeNameOptions = [{ label: 'All Employees', value: '' }];
            });
    }
    
    //Load departments for filter dropdown
    loadDepartments() {
        getDepartments()
            .then(result => {
                console.log('Departments loaded:', result);
                
                const deptOptions = [{ label: 'All Departments', value: '' }];
                
                if (result && result.length > 0) {
                    result.forEach(dept => {
                        deptOptions.push({
                            label: dept,
                            value: dept
                        });
                    });
                }
                
                this.departmentOptions = deptOptions;
                console.log('Department options:', this.departmentOptions);
                
            })
            .catch(error => {
                console.error('Error loading departments:', error);
                this.departmentOptions = [{ label: 'All Departments', value: '' }];
            });
    }
    
    // ============================================
    // DATA LOADING 
    // ============================================
    //Load attendance data from Apex
    loadAttendanceData() {
        this.isLoading = true;
        this.hasError = false;
        this.errorMessage = '';
        
        console.log('=== Loading Attendance Data ===');
        console.log('Filters:', {
            employeeId: this.employeeIdFilter,
            employeeName: this.employeeNameFilter,
            department: this.departmentFilter,
            startDate: this.startDate,
            endDate: this.endDate,
            pageSize: this.pageSize,
            pageNumber: this.currentPage,
            sortField: this.sortedBy || 'Date__c',
            sortDirection: this.sortDirection
        });
        
        // Build filter parameters
        const filterParams = {
            employeeId: this.employeeIdFilter,
            employeeName: this.employeeNameFilter,
            department: this.departmentFilter,
            startDate: this.startDate,
            endDate: this.endDate,
            pageSize: parseInt(this.pageSize),
            pageNumber: this.currentPage,
            sortField: this.sortedBy || 'Date__c',
            sortDirection: this.sortDirection.toUpperCase()
        };
        
        // Call Apex method
        getAdminAttendanceRecords({ filterParams: filterParams })
            .then(result => {
                console.log('✅ Attendance data loaded successfully');
                console.log('Result:', result);
                
                if (result.success) {
                    this.displayedRecords = result.records || [];
                    this.totalRecords = result.totalRecords || 0;
                    this.totalPages = result.totalPages || 0;
                    
                    console.log('Records displayed:', this.displayedRecords.length);
                    console.log('Total records:', this.totalRecords);
                } else {
                    this.handleError(result.error || 'Failed to load attendance data');
                }
                
                this.isLoading = false;
                
            })
            .catch(error => {
                console.error('❌ Error loading attendance data:', error);
                this.handleError(this.parseError(error));
                this.isLoading = false;
            });
    }
    
// FILTER HANDLERS

handleEmployeeIdChange(event) {
    this.employeeIdFilter = event.target.value;
    
    if (this.employeeIdFilter && this.employeeIdFilter.length >= 1) {
        this.searchEmployeesByField('employeeId', this.employeeIdFilter);
    } else {
        this.showEmployeeIdSuggestions = false;
        this.employeeIdSuggestions = [];
    }
}

handleEmployeeNameChange(event) {
    this.employeeNameFilter = event.target.value;
    
    if (this.employeeNameFilter && this.employeeNameFilter.length >= 2) {
        this.searchEmployeesByField('name', this.employeeNameFilter);
    } else {
        this.showEmployeeNameSuggestions = false;
        this.employeeNameSuggestions = [];
    }
}

searchEmployeesByField(fieldType, searchTerm) {
    searchEmployeesLightweight({ 
        searchType: fieldType,
        searchTerm: searchTerm
    })
    .then(result => {
        if (fieldType === 'employeeId') {
            this.employeeIdSuggestions = result;
            this.showEmployeeIdSuggestions = result.length > 0;
        } else if (fieldType === 'name') {
            this.employeeNameSuggestions = result;
            this.showEmployeeNameSuggestions = result.length > 0;
        }
    })
    .catch(error => {
        console.error('Error searching employees:', error);
        this.showToast('Error', 'Failed to search employees', 'error');
    });
}

handleEmployeeIdSuggestionClick(event) {
    const selectedId = event.currentTarget.dataset.id;
    const selectedName = event.currentTarget.dataset.name;
    const selectedEmpId = event.currentTarget.dataset.empid;
    
    this.employeeIdFilter = selectedEmpId;
    this.employeeNameFilter = selectedName;
    this.showEmployeeIdSuggestions = false;
    this.employeeIdSuggestions = [];
}

handleEmployeeNameSuggestionClick(event) {
    const selectedId = event.currentTarget.dataset.id;
    const selectedName = event.currentTarget.dataset.name;
    const selectedEmpId = event.currentTarget.dataset.empid;
    
    this.employeeNameFilter = selectedName;
    this.employeeIdFilter = selectedEmpId;
    this.showEmployeeNameSuggestions = false;
    this.employeeNameSuggestions = [];
}
    
    handleDepartmentChange(event) {
        this.departmentFilter = event.detail.value;
        console.log('Department filter:', this.departmentFilter);
    }
    
    handleStartDateChange(event) {
        this.startDate = event.target.value;
        console.log('Start date:', this.startDate);
    }
    
    handleEndDateChange(event) {
        this.endDate = event.target.value;
        console.log('End date:', this.endDate);
    }
    
    handleToggleFilters() {
        this.filtersExpanded = !this.filtersExpanded;
        console.log('Filters expanded:', this.filtersExpanded);
    }
    
    /**
     * ✅ UPDATED: Clear filters and reset to initial state
     */
    handleClearFilters() {
        console.log('Clearing all filters...');
        
        // Reset all filter values
        this.employeeIdFilter = '';
        this.employeeNameFilter = '';
        this.departmentFilter = '';


        // Clear suggestions
    this.showEmployeeIdSuggestions = false;
    this.showEmployeeNameSuggestions = false;
    this.employeeIdSuggestions = [];
    this.employeeNameSuggestions = [];
        
        // Reset to default date range (last 7 days)
        const today = new Date();
        const sevenDaysAgo = new Date();
        sevenDaysAgo.setDate(today.getDate() - 7);
        
        this.startDate = this.formatDateForInput(sevenDaysAgo);
        this.endDate = this.formatDateForInput(today);
        
        // Reset pagination
        this.currentPage = 1;
        
        // ✅ CHANGED: Reset filters applied flag and clear records
        this.filtersHaveBeenApplied = false;
        this.displayedRecords = [];
        this.totalRecords = 0;
        this.totalPages = 0;
        
        this.showToast('Filters Cleared', 'All filters have been reset. Apply filters to view records.', 'info');
    }
    
    /**
     * ✅ UPDATED: Apply filters and load data
     */
    handleApplyFilters() {
        console.log('Applying filters...');
        
        // Reset to first page
        this.currentPage = 1;
        
        // ✅ NEW: Mark that filters have been applied
        this.filtersHaveBeenApplied = true;
        
        // Show toast
        this.showToast('Filters Applied', 'Loading filtered attendance data...', 'info');
        
        // Load data with filters
        this.loadAttendanceData();
    }
    
    // ============================================
    // SORTING HANDLERS
    // ============================================
    
    handleSort(event) {
        const field = event.currentTarget.dataset.field;
        console.log('Sorting by field:', field);
        
        // Toggle sort direction if same field
        if (this.sortedBy === field) {
            this.sortDirection = this.sortDirection === 'asc' ? 'desc' : 'asc';
        } else {
            this.sortedBy = field;
            this.sortDirection = 'asc';
        }
        
        console.log('Sort direction:', this.sortDirection);
        
        // Map frontend field names to backend field names
        const fieldMapping = {
            'employeeId': 'Employee_Name__r.Employee_IDs__c',
            'employeeName': 'Employee_Name__r.Name',
            'managerName': 'Employee_Name__r.Manager.Name',
            'department': 'Employee_Name__r.Department',
            'date': 'Date__c',
            'status': 'status', // 🟢 Sort mapping for Status / Work Mode column
            'checkInTime': 'Check_In_Time__c',
            'checkOutTime': 'Check_Out_Time__c',
            'hoursWorked': 'Hours_Worked__c',
            'location': 'Check_In_Location_Name__c',
            'wfhApprovalStatusText': 'WFH_Approval_Status__c'
        };
        
        this.sortedBy = fieldMapping[field] || field;
        
        // Reload data with new sort
        this.loadAttendanceData();
    }
    
    // ============================================
    // PAGINATION HANDLERS
    // ============================================
    
    handlePreviousPage() {
        if (this.currentPage > 1) {
            this.currentPage--;
            console.log('Previous page:', this.currentPage);
            this.loadAttendanceData();
        }
    }
    
    handleNextPage() {
        if (this.currentPage < this.totalPages) {
            this.currentPage++;
            console.log('Next page:', this.currentPage);
            this.loadAttendanceData();
        }
    }
    
    handlePageSizeChange(event) {
        this.pageSize = parseInt(event.detail.value);
        this.currentPage = 1; // Reset to first page
        console.log('Page size changed to:', this.pageSize);
        this.loadAttendanceData();
    }
    
    // ============================================
    // ACTION HANDLERS
    // ============================================
    
    /**
     * ✅ FIXED: Export CSV with proper file download (LWS compatible)
     */
    handleExportExcel() {
        this.handleExportCSV();
    }
    
    handleExportCSV() {
        console.log('Exporting attendance data...');
        
        if (!this.filtersHaveBeenApplied) {
            this.showToast('No Data', 'Please apply filters first to export data', 'warning');
            return;
        }
        
        this.isLoading = true;
        
        // Build filter parameters
        const filterParams = {
            employeeId: this.employeeIdFilter,
            employeeName: this.employeeNameFilter,
            department: this.departmentFilter,
            startDate: this.startDate,
            endDate: this.endDate,
            pageSize: 10000, // Export all records
            pageNumber: 1,
            sortField: this.sortedBy || 'Date__c',
            sortDirection: this.sortDirection.toUpperCase()
        };
        
        exportAttendanceToCSV({ filterParams: filterParams })
            .then(csvContent => {
                console.log('✅ Export data retrieved, building styled Excel (.xlsx) report');
                
                try {
                    this.downloadExcelFile(csvContent);
                    this.showToast('Success', 'Attendance Excel report (.xlsx) downloaded successfully', 'success');
                } catch (excelError) {
                    console.warn('Excel export error, falling back to CSV:', excelError);
                    this.downloadCSVFile(csvContent);
                    this.showToast('Success', 'Attendance report downloaded successfully', 'success');
                }
                
                this.isLoading = false;
            })
            .catch(error => {
                console.error('❌ Export error:', error);
                this.showToast('Error', 'Failed to export: ' + this.parseError(error), 'error');
                this.isLoading = false;
            });
    }
    
    /**
     * ✅ Download formatted Excel (.xlsx) spreadsheet with bold headers, color-coded work statuses, and gridlines
     */
    downloadExcelFile(csvContent) {
        const zipBytes = this.generateXLSXFromCSV(csvContent);
        
        let blob;
        let url;
        try {
            blob = new Blob([zipBytes], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' });
            url = URL.createObjectURL(blob);
        } catch (e1) {
            // LWS restricts certain MIME types. Fallback to text/plain which is whitelisted by LWS for downloads
            blob = new Blob([zipBytes], { type: 'text/plain' });
            url = URL.createObjectURL(blob);
        }
        
        const hiddenElement = document.createElement('a');
        hiddenElement.href = url;
        hiddenElement.download = `Attendance_Report_${this.getCurrentDateTimeString()}.xlsx`;
        hiddenElement.style.display = 'none';
        
        document.body.appendChild(hiddenElement);
        hiddenElement.click();
        document.body.removeChild(hiddenElement);
        
        setTimeout(() => {
            URL.revokeObjectURL(url);
        }, 1000);
    }

    /**
     * Generates genuine OpenXML Spreadsheet (.xlsx) binary bytes from CSV content
     */
    generateXLSXFromCSV(csvContent) {
        const rows = this.parseCSV(csvContent);
        if (!rows || rows.length === 0) {
            throw new Error('No records available to export');
        }

        const contentTypes = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
  <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>
</Types>`;

        const rels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>`;

        const wbRels = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
  <Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/>
</Relationships>`;

        const workbook = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets>
    <sheet name="Attendance Report" sheetId="1" r:id="rId1"/>
  </sheets>
</workbook>`;

        const styles = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <fonts count="8">
    <font><sz val="10"/><name val="Calibri"/><color rgb="FF181818"/></font>
    <font><b/><sz val="11"/><name val="Calibri"/><color rgb="FFFFFFFF"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF2E844A"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF0176D3"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFB86700"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FFEA001E"/></font>
    <font><sz val="10"/><name val="Calibri"/><color rgb="FF706E6B"/></font>
    <font><b/><sz val="10"/><name val="Calibri"/><color rgb="FF7F27CB"/></font>
  </fonts>
  <fills count="9">
    <fill><patternFill patternType="none"/></fill>
    <fill><patternFill patternType="gray125"/></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FF0070D2"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F5E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFE8F4F9"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFFF4E5"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFFDE8E8"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3F3F3"/></patternFill></fill>
    <fill><patternFill patternType="solid"><fgColor rgb="FFF3E8FD"/></patternFill></fill>
  </fills>
  <borders count="3">
    <border><left/><right/><top/><bottom/><diagonal/></border>
    <border>
      <left style="thin"><color rgb="FFD8DDE6"/></left>
      <right style="thin"><color rgb="FFD8DDE6"/></right>
      <top style="thin"><color rgb="FFD8DDE6"/></top>
      <bottom style="thin"><color rgb="FFD8DDE6"/></bottom>
    </border>
    <border>
      <left style="thin"><color rgb="FF005FB2"/></left>
      <right style="thin"><color rgb="FF005FB2"/></right>
      <top style="thin"><color rgb="FF005FB2"/></top>
      <bottom style="thin"><color rgb="FF005FB2"/></bottom>
    </border>
  </borders>
  <cellStyleXfs count="1">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>
  </cellStyleXfs>
  <cellXfs count="9">
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="1" fillId="2" borderId="2" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center" wrapText="1"/>
    </xf>
    <xf numFmtId="0" fontId="2" fillId="3" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="3" fillId="4" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="4" fillId="5" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="5" fillId="6" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="6" fillId="7" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="7" fillId="8" borderId="1" xfId="0" applyFont="1" applyFill="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
    <xf numFmtId="0" fontId="0" fillId="0" borderId="1" xfId="0" applyFont="1" applyBorder="1" applyAlignment="1">
      <alignment horizontal="center" vertical="center"/>
    </xf>
  </cellXfs>
</styleSheet>`;

        let sheetDataXml = '';
        const headerRow = rows[0];
        sheetDataXml += '<row r="1" ht="28" customHeight="1">';
        for (let c = 0; c < headerRow.length; c++) {
            const colLetter = this.getColumnLetter(c + 1);
            sheetDataXml += `<c r="${colLetter}1" t="inlineStr" s="1"><is><t>${this.escapeXml(headerRow[c])}</t></is></c>`;
        }
        sheetDataXml += '</row>';

        for (let r = 1; r < rows.length; r++) {
            const row = rows[r];
            const rowNum = r + 1;
            sheetDataXml += `<row r="${rowNum}" ht="22" customHeight="1">`;
            
            for (let c = 0; c < row.length; c++) {
                const colLetter = this.getColumnLetter(c + 1);
                const val = row[c] !== undefined ? row[c] : '';
                
                let sIdx = 0;
                if (c === 5) {
                    sIdx = this.getStatusStyleIndex(val);
                } else if (c === 0 || c === 4 || c === 6 || c === 7 || c === 8 || c === 10) {
                    sIdx = 8;
                }
                
                sheetDataXml += `<c r="${colLetter}${rowNum}" t="inlineStr" s="${sIdx}"><is><t>${this.escapeXml(val)}</t></is></c>`;
            }
            sheetDataXml += '</row>';
        }

        const sheet1 = `<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetViews>
    <sheetView tabSelected="1" workbookViewId="0">
      <pane ySplit="1" topLeftCell="A2" activePane="bottomLeft" state="frozen"/>
    </sheetView>
  </sheetViews>
  <cols>
    <col min="1" max="1" width="16" customWidth="1"/>
    <col min="2" max="2" width="26" customWidth="1"/>
    <col min="3" max="3" width="22" customWidth="1"/>
    <col min="4" max="4" width="20" customWidth="1"/>
    <col min="5" max="5" width="14" customWidth="1"/>
    <col min="6" max="6" width="22" customWidth="1"/>
    <col min="7" max="7" width="16" customWidth="1"/>
    <col min="8" max="8" width="16" customWidth="1"/>
    <col min="9" max="9" width="15" customWidth="1"/>
    <col min="10" max="10" width="20" customWidth="1"/>
    <col min="11" max="11" width="16" customWidth="1"/>
  </cols>
  <sheetData>
    ${sheetDataXml}
  </sheetData>
</worksheet>`;

        const files = [
            { name: '[Content_Types].xml', data: contentTypes },
            { name: '_rels/.rels', data: rels },
            { name: 'xl/_rels/workbook.xml.rels', data: wbRels },
            { name: 'xl/workbook.xml', data: workbook },
            { name: 'xl/styles.xml', data: styles },
            { name: 'xl/worksheets/sheet1.xml', data: sheet1 }
        ];

        return this.createZip(files);
    }

    /**
     * Parse CSV string into array of rows and cell values
     */
    parseCSV(csvText) {
        const lines = [];
        let row = [];
        let inQuotes = false;
        let currentField = '';
        
        for (let i = 0; i < csvText.length; i++) {
            const c = csvText[i];
            const next = csvText[i + 1];
            
            if (c === '"') {
                if (inQuotes && next === '"') {
                    currentField += '"';
                    i++;
                } else {
                    inQuotes = !inQuotes;
                }
            } else if (c === ',' && !inQuotes) {
                row.push(currentField);
                currentField = '';
            } else if ((c === '\r' || c === '\n') && !inQuotes) {
                if (c === '\r' && next === '\n') {
                    i++;
                }
                row.push(currentField);
                currentField = '';
                if (row.length > 0 && (row.length > 1 || row[0] !== '')) {
                    lines.push(row);
                }
                row = [];
            } else {
                currentField += c;
            }
        }
        if (currentField || row.length > 0) {
            row.push(currentField);
            if (row.length > 0 && (row.length > 1 || row[0] !== '')) {
                lines.push(row);
            }
        }
        return lines;
    }

    /**
     * Map Status / Work Mode value to style index
     */
    getStatusStyleIndex(statusText) {
        if (!statusText) return 8;
        const s = String(statusText).toLowerCase();
        if (s.includes('office') || s.includes('wfo')) {
            return 2; // Green
        } else if (s.includes('home') || s.includes('wfh')) {
            return 3; // Blue
        } else if (s.includes('leave')) {
            return 4; // Orange/Amber
        } else if (s.includes('missing')) {
            return 5; // Red
        } else if (s.includes('weekend')) {
            return 6; // Gray
        } else if (s.includes('holiday')) {
            return 7; // Purple
        }
        return 8; // Centered
    }

    /**
     * Escape XML special characters
     */
    escapeXml(value) {
        if (value === null || value === undefined) {
            return '';
        }
        return String(value)
            .replace(/&/g, '&amp;')
            .replace(/</g, '&lt;')
            .replace(/>/g, '&gt;')
            .replace(/"/g, '&quot;')
            .replace(/'/g, '&apos;');
    }

    /**
     * Get Excel column letter (1 -> A, 2 -> B, etc.)
     */
    getColumnLetter(colIndex) {
        let letter = '';
        let temp = colIndex;
        while (temp > 0) {
            const mod = (temp - 1) % 26;
            letter = String.fromCharCode(65 + mod) + letter;
            temp = Math.floor((temp - mod) / 26);
        }
        return letter;
    }

    /**
     * Creates an uncompressed Store-method ZIP archive
     */
    createZip(files) {
        const encoder = new TextEncoder();
        const fileEntries = [];
        let localHeadersSize = 0;

        for (const file of files) {
            const nameBytes = encoder.encode(file.name);
            const dataBytes = typeof file.data === 'string' ? encoder.encode(file.data) : file.data;
            const crc = this.crc32(dataBytes);
            fileEntries.push({
                nameBytes,
                dataBytes,
                crc,
                uncompressedSize: dataBytes.length,
                compressedSize: dataBytes.length,
                offset: localHeadersSize
            });
            localHeadersSize += 30 + nameBytes.length + dataBytes.length;
        }

        let centralDirSize = 0;
        for (const entry of fileEntries) {
            centralDirSize += 46 + entry.nameBytes.length;
        }

        const totalSize = localHeadersSize + centralDirSize + 22;
        const buffer = new Uint8Array(totalSize);
        const view = new DataView(buffer.buffer);
        let pos = 0;

        // Local File Headers + Data
        for (const entry of fileEntries) {
            view.setUint32(pos, 0x04034b50, true); pos += 4;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 0x0800, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, entry.crc, true); pos += 4;
            view.setUint32(pos, entry.compressedSize, true); pos += 4;
            view.setUint32(pos, entry.uncompressedSize, true); pos += 4;
            view.setUint16(pos, entry.nameBytes.length, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            buffer.set(entry.nameBytes, pos); pos += entry.nameBytes.length;
            buffer.set(entry.dataBytes, pos); pos += entry.dataBytes.length;
        }

        const centralDirOffset = pos;

        // Central Directory
        for (const entry of fileEntries) {
            view.setUint32(pos, 0x02014b50, true); pos += 4;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 20, true); pos += 2;
            view.setUint16(pos, 0x0800, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, entry.crc, true); pos += 4;
            view.setUint32(pos, entry.compressedSize, true); pos += 4;
            view.setUint32(pos, entry.uncompressedSize, true); pos += 4;
            view.setUint16(pos, entry.nameBytes.length, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint16(pos, 0, true); pos += 2;
            view.setUint32(pos, 0, true); pos += 4;
            view.setUint32(pos, entry.offset, true); pos += 4;
            buffer.set(entry.nameBytes, pos); pos += entry.nameBytes.length;
        }

        // End of Central Directory
        view.setUint32(pos, 0x06054b50, true); pos += 4;
        view.setUint16(pos, 0, true); pos += 2;
        view.setUint16(pos, 0, true); pos += 2;
        view.setUint16(pos, fileEntries.length, true); pos += 2;
        view.setUint16(pos, fileEntries.length, true); pos += 2;
        view.setUint32(pos, centralDirSize, true); pos += 4;
        view.setUint32(pos, centralDirOffset, true); pos += 4;
        view.setUint16(pos, 0, true); pos += 2;

        return buffer;
    }

    /**
     * Fast CRC32 calculation
     */
    crc32(bytes) {
        if (!this._crcTable) {
            const table = new Uint32Array(256);
            for (let n = 0; n < 256; n++) {
                let c = n;
                for (let k = 0; k < 8; k++) {
                    c = ((c & 1) ? (0xEDB88320 ^ (c >>> 1)) : (c >>> 1));
                }
                table[n] = c;
            }
            this._crcTable = table;
        }
        let crc = 0 ^ (-1);
        for (let i = 0; i < bytes.length; i++) {
            crc = (crc >>> 8) ^ this._crcTable[(crc ^ bytes[i]) & 0xFF];
        }
        return (crc ^ (-1)) >>> 0;
    }

    /**
     * ✅ Fallback CSV download
     */
    downloadCSVFile(csvContent) {
        // LWS requires an explicitly whitelisted MIME type like 'text/plain'
        // UTF-8 BOM (\uFEFF) ensures Excel properly handles characters
        const universalBOM = '\uFEFF';
        const blob = new Blob([universalBOM + csvContent], { type: 'text/plain' });
        const url = URL.createObjectURL(blob);
        
        // Create hidden link element
        const hiddenElement = document.createElement('a');
        hiddenElement.href = url;
        hiddenElement.download = `Attendance_Report_${this.getCurrentDateTimeString()}.csv`;
        hiddenElement.style.display = 'none';
        
        document.body.appendChild(hiddenElement);
        hiddenElement.click();
        document.body.removeChild(hiddenElement);
        
        // Revoke Object URL to free memory
        setTimeout(() => {
            URL.revokeObjectURL(url);
        }, 500);
    }
    
    handleFullscreen() {
        this.showToast('Fullscreen', 'Fullscreen mode coming soon', 'info');
    }
    
    handleRefresh() {
        console.log('Refreshing data...');
        this.showToast('Refreshing', 'Reloading dropdown options...', 'info');
        
        // Reload dropdown options
        this.loadEmployeeIds();
        this.loadEmployeeNames();
        this.loadDepartments();
        
        // Only reload table data if filters have been applied
        if (this.filtersHaveBeenApplied) {
            this.loadAttendanceData();
        }
    }
    
    handleRetry() {
        console.log('Retrying to load data...');
        this.loadAttendanceData();
    }
    
    handleViewDetails(event) {
        const recordId = event.target.dataset.id;
        console.log('View details for record:', recordId);
        this.showToast('View Details', `Opening details for record ${recordId}`, 'info');
    }
    
    handleEditRecord(event) {
        const recordId = event.target.dataset.id;
        console.log('Edit record:', recordId);
        this.showToast('Edit Record', `Editing record ${recordId}`, 'info');
    }
    
    handleExportIndividual(event) {
        const recordId = event.target.dataset.id;
        console.log('Export individual record:', recordId);
        this.showToast('Export Individual', `Exporting record ${recordId}`, 'info');
    }
    
    // ============================================
    // COMPUTED PROPERTIES
    // ============================================
    
    get filterToggleIcon() {
        return this.filtersExpanded ? 'utility:chevronup' : 'utility:chevrondown';
    }
    
    get filtersPanelClass() {
        return this.filtersExpanded ? 'filters-panel expanded' : 'filters-panel collapsed';
    }
    
    get hasRecords() {
        return this.displayedRecords && this.displayedRecords.length > 0;
    }
    
    get showPagination() {
        return this.hasRecords && !this.isLoading && !this.hasError;
    }
    
    get paginationStart() {
        return this.totalRecords === 0 ? 0 : (this.currentPage - 1) * this.pageSize + 1;
    }
    
    get paginationEnd() {
        const end = this.currentPage * this.pageSize;
        return end > this.totalRecords ? this.totalRecords : end;
    }
    
    get isFirstPage() {
        return this.currentPage === 1;
    }
    
    get isLastPage() {
        return this.currentPage >= this.totalPages;
    }
    
    get currentPageLabel() {
        return `Page ${this.currentPage} of ${this.totalPages}`;
    }
    
    get filtersApplied() {
        return this.employeeIdFilter || 
               this.employeeNameFilter || 
               this.departmentFilter;
    }
    
    get activeFiltersLabel() {
        let count = 0;
        if (this.employeeIdFilter) count++;
        if (this.employeeNameFilter) count++;
        if (this.departmentFilter) count++;
        
        return `${count} Active Filter${count !== 1 ? 's' : ''}`;
    }
    
    /**
     * ✅ NEW: Show initial message if filters haven't been applied yet
     */
    get showInitialMessage() {
        return !this.filtersHaveBeenApplied;
    }
    
    get pageSizeOptions() {
        return [
            { label: '10', value: '10' },
            { label: '20', value: '20' },
            { label: '50', value: '50' },
            { label: '100', value: '100' }
        ];
    }
    
    // ============================================
    // UTILITY METHODS
    // ============================================
    
    /**
     * Format date for input field (YYYY-MM-DD)
     */
    formatDateForInput(date) {
        const year = date.getFullYear();
        const month = String(date.getMonth() + 1).padStart(2, '0');
        const day = String(date.getDate()).padStart(2, '0');
        return `${year}-${month}-${day}`;
    }
    
    /**
     * Get current date time string for file names
     */
    getCurrentDateTimeString() {
        const now = new Date();
        const year = now.getFullYear();
        const month = String(now.getMonth() + 1).padStart(2, '0');
        const day = String(now.getDate()).padStart(2, '0');
        const hours = String(now.getHours()).padStart(2, '0');
        const minutes = String(now.getMinutes()).padStart(2, '0');
        const seconds = String(now.getSeconds()).padStart(2, '0');
        
        return `${year}${month}${day}_${hours}${minutes}${seconds}`;
    }
    
    /**
     * Parse error object to readable message
     */
    parseError(error) {
        if (!error) {
            return 'Unknown error occurred';
        }
        
        // Handle AuraHandledException
        if (error.body && error.body.message) {
            return error.body.message;
        }
        
        // Handle standard Error object
        if (error.message) {
            return error.message;
        }
        
        // Handle string errors
        if (typeof error === 'string') {
            return error;
        }
        
        // Fallback
        return JSON.stringify(error);
    }
    
    
//Handle error state
    
    handleError(errorMsg) {
        this.hasError = true;
        this.errorMessage = errorMsg;
        this.displayedRecords = [];
        this.totalRecords = 0;
        
        console.error('Error state:', errorMsg);
        this.showToast('Error', errorMsg, 'error');
    }
    
//Show toast notification
     
    showToast(title, message, variant) {
        const event = new ShowToastEvent({
            title: title,
            message: message,
            variant: variant,
            mode: 'dismissable',
            duration: variant === 'error' ? 8000 : 4000
        });
        this.dispatchEvent(event);
    }
}