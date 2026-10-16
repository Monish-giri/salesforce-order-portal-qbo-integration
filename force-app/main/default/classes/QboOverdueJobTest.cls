@IsTest
private class QboOverdueJobTest {
    @IsTest
    static void marksOpenPastDueInvoiceAsOverdue() {
        Account account = new Account(Name = 'Overdue Job Test Account');
        insert account;

        Order overdueOrder = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today().addDays(-30),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            QBO_Invoice_Id__c = 'OVERDUE-145',
            Invoice_Status__c = 'Invoiced',
            Invoice_Total__c = 35000,
            Invoice_Balance__c = 19000,
            Invoice_Due_Date__c = Date.today().addDays(-1),
            Payment_Status__c = 'Partially Paid'
        );
        insert overdueOrder;

        Test.startTest();
        new QboOverdueJob().execute(null);
        Test.stopTest();

        Order refreshedOrder = [
            SELECT Id, Invoice_Balance__c, Invoice_Due_Date__c,
                   Payment_Status__c, Last_QBO_Sync__c
            FROM Order
            WHERE Id = :overdueOrder.Id
        ];

        System.assertEquals(19000, refreshedOrder.Invoice_Balance__c);
        System.assertEquals(Date.today().addDays(-1), refreshedOrder.Invoice_Due_Date__c);
        System.assertEquals('Overdue', refreshedOrder.Payment_Status__c);
        System.assertNotEquals(null, refreshedOrder.Last_QBO_Sync__c);
    }

    @IsTest
    static void doesNotMarkPaidInvoiceAsOverdue() {
        Account account = new Account(Name = 'Paid Invoice Test Account');
        insert account;

        Order paidOrder = new Order(
            AccountId = account.Id,
            EffectiveDate = Date.today().addDays(-30),
            Status = 'Draft',
            Pricebook2Id = Test.getStandardPricebookId(),
            QBO_Invoice_Id__c = 'PAID-145',
            Invoice_Status__c = 'Invoiced',
            Invoice_Total__c = 35000,
            Invoice_Balance__c = 0,
            Invoice_Due_Date__c = Date.today().addDays(-1),
            Payment_Status__c = 'Paid'
        );
        insert paidOrder;

        Test.startTest();
        new QboOverdueJob().execute(null);
        Test.stopTest();

        Order refreshedOrder = [
            SELECT Id, Payment_Status__c, Last_QBO_Sync__c
            FROM Order
            WHERE Id = :paidOrder.Id
        ];

        System.assertEquals('Paid', refreshedOrder.Payment_Status__c);
        System.assertEquals(null, refreshedOrder.Last_QBO_Sync__c);
    }
}
