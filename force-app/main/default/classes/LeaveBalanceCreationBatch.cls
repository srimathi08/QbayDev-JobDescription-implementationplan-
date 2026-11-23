/**
 * Batch class to create leave balances for all employees
 */
public class LeaveBalanceCreationBatch implements Database.Batchable<SObject> {

    private String year;

    public LeaveBalanceCreationBatch(String year) {
        this.year = year;
    }

    /* =====================================================
     * START
     * ===================================================== */
    public Database.QueryLocator start(Database.BatchableContext bc) {

        return Database.getQueryLocator([
            SELECT Id,
                   Name,
                   Date_of_Joining__c,
                   Gender__c,
                   Marital_Status__c,
                   Number_of_Children__c,
                   Employment_Type__c,
                   Email,
                   Employee_IDs__c
            FROM User
            WHERE IsActive = true
            AND Employee_IDs__c != null
            AND Date_of_Joining__c != null
        ]);
    }

    /* =====================================================
     * EXECUTE
     * ===================================================== */
    public void execute(Database.BatchableContext bc, List<User> scope) {

        for (User emp : scope) {
            try {
                LeaveBalanceService.createEligibleBalancesForEmployee(
                    emp.Id,
                    this.year
                );
            } catch (Exception e) {
                System.debug(
                    'Error processing employee ' +
                    emp.Name +
                    ' (' + emp.Employee_IDs__c + '): ' +
                    e.getMessage()
                );
            }
        }
    }

    /* =====================================================
     * FINISH
     * ===================================================== */
    public void finish(Database.BatchableContext bc) {
        System.debug(
            'Leave balance creation batch completed for year: ' + this.year
        );
    }
public static void createEligibleBalancesForEmployee(Id employeeId, String year) {
    // ── Query all non-CO active Leave Types ──────────────────────────
    // CO is created on-demand — skip it here to avoid overwriting
    List<Leave_Type__c> leaveTypes = [
        SELECT Id, Leave_Code__c, Leave_Type_Name__c, Default_Allocation__c, Is_Active__c
        FROM Leave_Type__c
        WHERE Is_Active__c = true
        AND   Leave_Code__c != 'CO'   // ← KEY: Skip CO — handled by Stage 3
    ];
 
    if (leaveTypes.isEmpty()) return;
 
    // ── Get existing balances for this employee + year ────────────────
    List<Employee_Leave_Balance__c> existing = [
        SELECT Id, Leave_Type__c, Year__c
        FROM Employee_Leave_Balance__c
        WHERE Employee__c = :employeeId
        AND   Year__c     = :year
    ];
 
    Set<Id> existingLeaveTypeIds = new Set<Id>();
    for (Employee_Leave_Balance__c lb : existing) {
        existingLeaveTypeIds.add(lb.Leave_Type__c);
    }
 
    // ── Create missing balances ───────────────────────────────────────
    List<Employee_Leave_Balance__c> toInsert = new List<Employee_Leave_Balance__c>();
    for (Leave_Type__c lt : leaveTypes) {
        if (!existingLeaveTypeIds.contains(lt.Id)) {
            toInsert.add(new Employee_Leave_Balance__c(
                Employee__c        = employeeId,
                Leave_Type__c      = lt.Id,
                Year__c            = year,
                Total_Allocated__c = lt.Default_Allocation__c != null ? lt.Default_Allocation__c : 0,
               // Available__c       = lt.Default_Allocation__c != null ? lt.Default_Allocation__c : 0,
                Used__c            = 0,
                Pending_Approval__c         = 0
            ));
        }
    }
 
    if (!toInsert.isEmpty()) {
        insert toInsert;
        System.debug('✅ Created ' + toInsert.size() + ' leave balances for employee: ' + employeeId);
    }
}
 
}