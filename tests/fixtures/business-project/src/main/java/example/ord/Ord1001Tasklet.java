package example.ord;

/** 매일 승인된 주문을 출고 기준 데이터로 확정한다. */
public class Ord1001Tasklet {
    public void execute(String businessDate) {
        new Ord1001Service().confirmShipmentBase(businessDate);
    }
}
