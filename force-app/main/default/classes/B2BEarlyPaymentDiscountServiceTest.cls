@IsTest
private class B2BEarlyPaymentDiscountServiceTest {
    @IsTest
    static void firstWeekGetsSevenPercent() {
        Date invoiceDate = Date.newInstance(2026, 10, 1);
        Date paymentDate = Date.newInstance(2026, 10, 1);

        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(invoiceDate, Date.newInstance(2026, 10, 30), 10000, paymentDate);

        System.assertEquals(true, result.eligible);
        System.assertEquals(7, result.discountPercent);
        System.assertEquals(700, result.discountAmount);
        System.assertEquals(9300, result.payableAmount);
    }

    @IsTest
    static void secondWeekGetsFivePercent() {
        Date invoiceDate = Date.newInstance(2026, 10, 1);
        Date paymentDate = Date.newInstance(2026, 10, 8);

        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(invoiceDate, Date.newInstance(2026, 10, 30), 10000, paymentDate);

        System.assertEquals(5, result.discountPercent);
        System.assertEquals(500, result.discountAmount);
        System.assertEquals(9500, result.payableAmount);
    }

    @IsTest
    static void thirdWeekToDueGetsTwoPercent() {
        Date invoiceDate = Date.newInstance(2026, 10, 1);
        Date paymentDate = Date.newInstance(2026, 10, 15);

        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(invoiceDate, Date.newInstance(2026, 10, 30), 10000, paymentDate);

        System.assertEquals(2, result.discountPercent);
        System.assertEquals(200, result.discountAmount);
        System.assertEquals(9800, result.payableAmount);
    }

    @IsTest
    static void afterDueDateGetsNoDiscount() {
        Date invoiceDate = Date.newInstance(2026, 10, 1);
        Date dueDate = Date.newInstance(2026, 10, 30);
        Date paymentDate = Date.newInstance(2026, 10, 31);

        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(invoiceDate, dueDate, 10000, paymentDate);

        System.assertEquals(false, result.eligible);
        System.assertEquals(0, result.discountPercent);
        System.assertEquals(10000, result.payableAmount);
    }

    @IsTest
    static void invalidDatesReturnNoDiscount() {
        B2BEarlyPaymentDiscountService.DiscountResult result =
            B2BEarlyPaymentDiscountService.calculate(null, null, 10000, Date.today());

        System.assertEquals(false, result.eligible);
        System.assertEquals(0, result.discountPercent);
    }

    @IsTest
    static void activeScheduleComesFromMetadata() {
        List<B2BEarlyPaymentDiscountService.DiscountRule> schedule =
            B2BEarlyPaymentDiscountService.getActiveSchedule();

        System.assertEquals(3, schedule.size());
        System.assertEquals(1, schedule[0].dayFrom);
        System.assertEquals(7, schedule[0].dayTo);
        System.assertEquals(7, schedule[0].discountPercent);
        System.assertEquals(8, schedule[1].dayFrom);
        System.assertEquals(14, schedule[1].dayTo);
        System.assertEquals(5, schedule[1].discountPercent);
        System.assertEquals(15, schedule[2].dayFrom);
        System.assertEquals(30, schedule[2].dayTo);
        System.assertEquals(2, schedule[2].discountPercent);
    }
}
