package example.common;

/** 기술 공통 로그 리스너: 업무 질문의 primary가 되어서는 안 된다. */
public class CommonJobListener {
    public void beforeJob() {}
    public void afterJob() {}
    public void onError() {}
    public void writeLog() {}
    public void updateStatus() {}
    public void retry() {}
    public void cleanup() {}
    public void notifyOperator() {}
}
