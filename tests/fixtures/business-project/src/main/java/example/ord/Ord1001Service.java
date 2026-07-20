package example.ord;

/** 주문 승인 내역을 출고 준비 대상으로 전환한다. */
public class Ord1001Service {
    private Ord1001Mapper mapper;
    public void confirmShipmentBase(String businessDate) {
        mapper.deleteShipmentBase(businessDate);
        mapper.insertShipmentBase(businessDate);
    }
}
