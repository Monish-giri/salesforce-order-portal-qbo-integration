public with sharing class QboOverdueJob implements Schedulable {
    public void execute(SchedulableContext context) {
        Date today = Date.today();

        List<Order> overdueOrders = [
            SELECT Id, Invoice_Due_Date__c, Invoice_Balance__c, Payment_Status__c
            FROM Order
            WHERE Invoice_Status__c = 'Invoiced'
              AND Invoice_Due_Date__c < :today
              AND Invoice_Balance__c > 0
              AND Payment_Status__c != 'Paid'
            WITH SYSTEM_MODE
        ];

        if (overdueOrders.isEmpty()) {
            return;
        }

        for (Order orderRecord : overdueOrders) {
            orderRecord.Payment_Status__c = 'Overdue';
            orderRecord.Last_QBO_Sync__c = System.now();
        }

        Database.update(overdueOrders, AccessLevel.SYSTEM_MODE);
    }
}
